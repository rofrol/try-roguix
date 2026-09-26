;;; Roguix — guest side of the launcher's macOS integrations.
;;;
;;; The host side and its wire protocols come from Try Omarchy, unchanged,
;;; and so do the guest programs next to this module (reviewed there as the
;;; Arch guest's scripts); here Shepherd services and login hooks start them
;;; instead of systemd units.
;;;
;;; A UEFI guest boots its own GRUB, so the launcher passes its `name=value'
;;; settings as SMBIOS OEM strings (type 11) rather than on a kernel command
;;; line, and
;;; roguix-host-settings writes them to %roguix-host-settings-file in the
;;; command line's format. That file lives in /run: settings last one boot.
(define-module (roguix integrations)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system linux-module)
  #:use-module (guix build-system trivial)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages gnome)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages pulseaudio)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages python)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages xdisorg)
  #:use-module ((roguix apps) #:select (gum-bin))
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services linux)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services ssh)
  #:use-module (gnu system pam)
  #:export (%roguix-host-settings-file
            roguix-host-settings-service-type
            roguix-mac-share
            roguix-mac-share-service-type
            roguix-agent
            roguix-clipboard-bridge
            roguix-clipboard-service-type
            roguix-audio-bridge
            roguix-audio-service-type
            roguix-camera-bridge
            roguix-camera-service-type
            roguix-battery-module
            roguix-battery-service-type
            roguix-settings
            roguix-setup
            roguix-settings-service-type
            roguix-touch-id
            roguix-touch-id-service-type
            roguix-ssh-access-service-type))

(define %roguix-host-settings-file "/run/roguix/host-settings")

(define host-settings-program
  (program-file
   "roguix-host-settings"
   #~(begin
       (use-modules (ice-9 binary-ports) (ice-9 ftw) (ice-9 iconv) (ice-9 regex)
                    (rnrs bytevectors) (srfi srfi-1))

       (define directory "/sys/firmware/dmi/entries")
       ;; Exactly the launcher's argument shape; anything else is ignored.
       (define setting
         (make-regexp "^(omarchy|tryomarchy)\\.[a-z_]+=[A-Za-z0-9_.-]*$"))

       (define (oem-strings entry)
         ;; An SMBIOS structure: a formatted area whose length is byte 1,
         ;; then NUL-terminated strings ending with an empty one.
         (let* ((raw (call-with-input-file
                         (string-append directory "/" entry "/raw")
                       (lambda (port) (get-bytevector-all port))
                       #:binary #t))
                (start (bytevector-u8-ref raw 1))
                (text (bytevector->string
                       (let ((strings (make-bytevector
                                       (- (bytevector-length raw) start))))
                         (bytevector-copy! raw start strings 0
                                           (bytevector-length strings))
                         strings)
                       "ISO-8859-1")))
           (string-split text #\nul)))

       ;; A missing or unreadable table means no settings, never a failure:
       ;; the shared folder and the tty1 session start after this service.
       (define settings
         (catch #t
           (lambda ()
             (filter (lambda (value) (regexp-exec setting value))
                     (append-map oem-strings
                                 (or (scandir directory
                                              (lambda (name)
                                                (string-prefix? "11-" name)))
                                     '()))))
           (lambda (key . arguments)
             (format (current-error-port)
                     "roguix-host-settings: ignoring SMBIOS: ~a ~s~%"
                     key arguments)
             '())))

       (define target #$%roguix-host-settings-file)
       (define staging (string-append target ".new"))
       (unless (file-exists? (dirname target))
         (mkdir (dirname target) #o755))
       (call-with-output-file staging
         (lambda (port)
           (chmod port #o644)
           (display (string-join settings " ") port)
           (newline port)))
       (rename-file staging target))))

(define (host-settings-shepherd-service _)
  (list (shepherd-service
         (provision '(roguix-host-settings))
         (requirement '(file-systems))
         (one-shot? #t)
         (documentation "Record the launcher's settings for this boot.")
         (start #~(lambda _
                    (zero? (system* #$host-settings-program)))))))

(define roguix-host-settings-service-type
  (service-type
   (name 'roguix-host-settings)
   (extensions (list (service-extension shepherd-root-service-type
                                        host-settings-shepherd-service)))
   (default-value #f)
   (description "Write the launcher's SMBIOS OEM settings to /run/roguix.")))

;;; Shared folder: the launcher attaches virtio-9p with mount tag `mac' and
;;; passes the folder's name as omarchy.shared_folder_name. The mount runs as
;;; root before tty1 logs in; each login of the desktop account links ~/<name>.

(define roguix-mac-share
  (package
    (name "roguix-mac-share")
    (version "1")
    (source (local-file "mac-share"))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan #~'(("mac-share" "bin/roguix-mac-share"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'wrap
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((program (string-append #$output "/bin/roguix-mac-share")))
                (chmod program #o555)
                (wrap-program program
                  `("OMARCHY_MAC_SHARE_CMDLINE" = (#$%roguix-host-settings-file))
                  `("PATH" ":" prefix
                    ,(map (lambda (command)
                            (dirname (search-input-file inputs command)))
                          '("bin/base64" "bin/find" "bin/modprobe"
                            "bin/mount" "bin/mountpoint"))))))))))
    (inputs (list bash-minimal coreutils findutils kmod util-linux))
    (home-page "https://github.com/omacom/try-omarchy")
    (synopsis "Mount and link the Mac folder shared by the launcher")
    (description "Mount the launcher's virtio-9p share and link it into the
home directory under the Mac folder's own name.")
    (license license:expat)))

(define mac-share-program
  (file-append roguix-mac-share "/bin/roguix-mac-share"))

(define (mac-share-shepherd-service _)
  (list (shepherd-service
         (provision '(roguix-mac-share))
         (requirement '(file-systems udev kernel-module-loader
                        roguix-host-settings))
         (documentation "Mount the Mac folder shared by the launcher.")
         ;; tty1's session waits for this service; a failed mount is logged
         ;; by the script and must not keep the desktop from starting.
         (start #~(lambda _
                    (system* #$mac-share-program "--mount")
                    #t))
         (stop #~(lambda _
                   (system* #$mac-share-program "--unmount")
                   #f)))))

;; Sourced by every login shell; it links for the desktop account only and
;; is idempotent, so the serial console and SSH logins are harmless.
(define mac-share-link-script
  (mixed-text-file "roguix-mac-share-link.sh"
                   "if [ \"$(id -u)\" = 1000 ]; then\n  "
                   mac-share-program " --link 2>/dev/null || true\nfi\n"))

(define roguix-mac-share-service-type
  (service-type
   (name 'roguix-mac-share)
   (extensions
    (list (service-extension shepherd-root-service-type
                             mac-share-shepherd-service)
          (service-extension kernel-module-loader-service-type
                             (const '("9pnet_virtio" "9p")))
          (service-extension etc-profile-d-service-type
                             (const (list mac-share-link-script)))))
   (default-value #f)
   (description "Mount the launcher's shared Mac folder and link it at login.")))


;;; Session agents: the Arch guest runs its bridges as systemd user units
;;; with Restart=. Hyprland starts each one here through roguix-agent, which
;;; runs it while this compositor's socket and the bridge's virtio port exist,
;;; and restarts it 2 s after it exits (the bridges exit when the host side
;;; disconnects). Agents therefore end with the session.

(define roguix-agent
  (package
    (name "roguix-agent")
    (version "1")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((program (string-append #$output "/bin/roguix-agent")))
            (mkdir-p (dirname program))
            (call-with-output-file program
              (lambda (port)
                (format port "#!~a
# roguix-agent PORT PROGRAM...: keep PROGRAM running for this session.
[ -n \"$WAYLAND_DISPLAY\" ] || { echo 'roguix-agent: no Wayland session' >&2; exit 1; }
socket=\"$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY\"
port=$1
shift
while [ -S \"$socket\" ]; do
  [ -e \"$port\" ] && \"$@\"
  sleep 2
done
" #$(file-append bash-minimal "/bin/sh"))))
            (chmod program #o555)))))
    (home-page "https://github.com/omacom/try-omarchy")
    (synopsis "Restart a Roguix bridge for the life of the session")
    (description "Run a host bridge while the Wayland session and its virtio
port exist, restarting it after it exits.")
    (license license:expat)))

;; A guest script written for /usr/bin whose #!/usr/bin/python3 becomes Guix's Python and
;; whose tools are put on PATH. SOURCE is (local-file FILE), written at the
;; call site so it resolves next to this module.
(define* (guest-python-script name file source #:key (tools '())
                                   (inputs '()) synopsis)
  (package
    (name name)
    (version "1")
    (source source)
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan #~'((#$file #$(string-append "bin/" name)))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'wrap
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((program (string-append #$output "/bin/" #$name)))
                (chmod program #o555)
                (unless (null? '#$tools)
                  (wrap-program program
                    `("PATH" ":" prefix
                      ,(map (lambda (tool)
                              (dirname (search-input-file inputs tool)))
                            '#$tools))))))))))
    (inputs (cons* bash-minimal python-minimal inputs))
    (home-page "https://github.com/omacom/try-omarchy")
    (synopsis synopsis)
    (description synopsis)
    (license license:expat)))

;;; Clipboard: JSON lines on dev.tryomarchy.clipboard; wl-clipboard's
;;; data-control protocol observes and replaces the Hyprland selection.

(define roguix-clipboard-bridge
  (guest-python-script "roguix-clipboard-bridge" "clipboard-bridge"
                            (local-file "clipboard-bridge")
                            #:tools '("bin/wl-paste")
                            #:inputs (list wl-clipboard)
                            #:synopsis "Share the Wayland clipboard with macOS"))

(define roguix-clipboard-service-type
  (service-type
   (name 'roguix-clipboard)
   (extensions
    (list (service-extension udev-service-type
                             (const
                              (list (udev-rule
                                     "92-roguix-clipboard.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.clipboard\", GROUP=\"users\", MODE=\"0660\"\n"))))
          (service-extension profile-service-type
                             (const (list roguix-agent
                                          roguix-clipboard-bridge
                                          wl-clipboard)))))
   (default-value #f)
   (description "Install the clipboard bridge and its port permissions.")))

;;; SSH: the launcher adds tryomarchy.ssh_access=1 only while a forward to
;;; guest port 22 is configured. sshd is installed but never auto-started;
;;; this one-shot starts it for the current boot when that exact setting is
;;; present, and nothing is written for later boots.

(define (ssh-access-shepherd-service _)
  (list (shepherd-service
         (provision '(roguix-ssh-access))
         (requirement '(roguix-host-settings))
         (one-shot? #t)
         (documentation "Start sshd when the launcher forwards SSH.")
         (start #~(lambda _
                    (let ((settings
                           (false-if-exception
                            (call-with-input-file #$%roguix-host-settings-file
                              (@ (ice-9 rdelim) read-line)))))
                      (when (and (string? settings)
                                 (member "tryomarchy.ssh_access=1"
                                         (string-tokenize settings)))
                        (start-service (lookup-service 'ssh-daemon)))
                      #t))))))

(define roguix-ssh-access-service-type
  (service-type
   (name 'roguix-ssh-access)
   (extensions
    (list (service-extension shepherd-root-service-type
                             ssh-access-shepherd-service)))
   (default-value #f)
   (description "Start the SSH daemon only when the launcher forwards SSH.")))

;;; Audio: sound itself flows through QEMU's intel-hda; the bridge only mirrors
;;; the Mac's devices as PipeWire remap endpoints and relays the selection
;;; over dev.tryomarchy.audio, driving pipewire-pulse through pactl. PipeWire,
;;; WirePlumber and pipewire-pulse run per session like the bridges; the
;;; Arch guest's graph quantum setting for the emulated HDA is installed as is.

(define roguix-audio-bridge
  (guest-python-script "roguix-audio-bridge" "audio-bridge"
                            (local-file "audio-bridge")
                            #:tools '("bin/pactl")
                            #:inputs (list pulseaudio)
                            #:synopsis "Expose macOS audio devices to PipeWire"))

(define roguix-audio-service-type
  (service-type
   (name 'roguix-audio)
   (extensions
    (list (service-extension udev-service-type
                             (const
                              (list (udev-rule
                                     "91-roguix-audio.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.audio\", GROUP=\"audio\", MODE=\"0660\"\n"))))
          (service-extension etc-service-type
                             (const
                              `(("pipewire/pipewire.conf.d/90-try-omarchy-quantum.conf"
                                 ,(local-file "pipewire-quantum.conf")))))
          (service-extension profile-service-type
                             (const (list pipewire wireplumber pulseaudio
                                          roguix-agent
                                          roguix-audio-bridge)))))
   (default-value #f)
   (description "Run PipeWire per session with the macOS audio bridge.")))

;;; Camera: the Mac camera streams 1280x720 NV12 frames over
;;; dev.tryomarchy.camera only while a Linux program reads /dev/video42, a
;;; v4l2loopback device (operating-system kernel-loadable-modules must list
;;; v4l2loopback-linux-module). Module options are the Arch guest's.

(define roguix-camera-bridge
  (guest-python-script "roguix-camera-bridge" "camera-bridge"
                            (local-file "camera-bridge")
                            #:synopsis "Expose the macOS camera as /dev/video42"))

(define roguix-camera-service-type
  (service-type
   (name 'roguix-camera)
   (extensions
    (list (service-extension kernel-module-loader-service-type
                             (const '("v4l2loopback")))
          (service-extension etc-service-type
                             (const
                              `(("modprobe.d/90-try-omarchy-camera.conf"
                                 ,(local-file "camera-modprobe.conf")))))
          (service-extension udev-service-type
                             (const
                              (list (udev-rule
                                     "94-roguix-camera.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.camera\", GROUP=\"video\", MODE=\"0660\"
KERNEL==\"video42\", SUBSYSTEM==\"video4linux\", GROUP=\"video\", MODE=\"0660\"\n"))))
          (service-extension profile-service-type
                             (const (list roguix-agent
                                          roguix-camera-bridge)))))
   (default-value #f)
   (description "Load v4l2loopback and install the macOS camera bridge.")))

;;; Battery: the launcher mirrors the Mac's battery as JSON lines on
;;; dev.tryomarchy.battery. Try Omarchy's kernel module publishes BAT0/ADP0
;;; power_supply devices fed through its sysfs state file, which the root
;;; agent writes; UPower and Omarchy's battery indicator read them as usual.

(define roguix-battery-module
  (package
    (name "roguix-battery-module")
    (version "1")
    (source (local-file "battery-module" #:recursive? #t))
    (build-system linux-module-build-system)
    (arguments (list #:tests? #f))
    (home-page "https://github.com/omacom/try-omarchy")
    (synopsis "Mirror the macOS battery as a Linux power_supply")
    (description "Kernel module exposing BAT0 and ADP0 whose state the
Roguix battery agent sets from the host.")
    (license license:gpl2)))

(define roguix-battery-bridge
  (guest-python-script "roguix-battery-bridge" "battery-bridge"
                       (local-file "battery-bridge")
                       #:synopsis "Mirror the macOS battery into the guest"))

(define (battery-shepherd-service _)
  (list (shepherd-service
         (provision '(roguix-battery))
         (requirement '(udev kernel-module-loader))
         (respawn? #t)
         (respawn-delay 1)
         (documentation "Mirror the macOS battery into the guest.")
         (start #~(lambda _
                    ;; Both exist only in a launcher VM with the module
                    ;; loaded; otherwise stay stopped.
                    (and (file-exists? "/dev/virtio-ports/dev.tryomarchy.battery")
                         (file-exists?
                          "/sys/devices/platform/try-omarchy-battery/state")
                         (fork+exec-command
                          (list #$(file-append roguix-battery-bridge
                                               "/bin/roguix-battery-bridge"))))))
         (stop #~(make-kill-destructor)))))

(define roguix-battery-service-type
  (service-type
   (name 'roguix-battery)
   (extensions
    (list (service-extension kernel-module-loader-service-type
                             (const '("try_omarchy_battery")))
          (service-extension udev-service-type
                             (const
                              (list (udev-rule
                                     "95-roguix-battery.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.battery\", MODE=\"0600\"\n"))))
          (service-extension shepherd-root-service-type
                             battery-shepherd-service)))
   (default-value #f)
   (description "Load the battery module and run the macOS battery agent.")))

;;; First-start setup: Omarchy's owner setup questions (keyboard, password,
;;; Git identity, host name, time zone) on tty1, suggested by the Mac; it
;;; writes the setup block of /etc/config.scm (see roguix-setup).

(define roguix-setup
  (guest-python-script "roguix-setup" "roguix-setup"
                       (local-file "roguix-setup")
                       #:tools '("bin/gum" "sbin/chpasswd" "bin/loadkeys"
                                 "bin/git" "bin/hostname" "bin/notify-send")
                       #:inputs (list gum-bin shadow kbd git
                                      inetutils libnotify)
                       #:synopsis "Ask Roguix's first-start questions"))

;;; Settings: Omarchy's Setup menu (omarchy-menu.py) and the desktop entry
;;; ask the Mac app to show its settings with one line on
;;; dev.tryomarchy.settings; the account's group reaches the port.

(define roguix-settings
  (package
    (name "roguix-settings")
    (version "1")
    (source (local-file "settings" #:recursive? #t))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~'(("roguix-settings" "bin/")
          ("try-roguix-settings.desktop" "share/applications/"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'wrap
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((program (string-append #$output "/bin/roguix-settings")))
                (chmod program #o555)
                (wrap-program program
                  `("PATH" ":" prefix
                    (,(dirname (search-input-file inputs "bin/notify-send")))))))))))
    (inputs (list bash-minimal python-minimal libnotify))
    (home-page "https://github.com/omacom/try-omarchy")
    (synopsis "Open the Try Roguix Mac app settings from the guest")
    (description "Ask the Mac app over dev.tryomarchy.settings to show its
settings window.")
    (license license:expat)))

(define roguix-settings-service-type
  (service-type
   (name 'roguix-settings)
   (extensions
    (list (service-extension udev-service-type
                             (const
                              (list (udev-rule
                                     "92-roguix-settings.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.settings\", GROUP=\"users\", MODE=\"0660\"\n"))))
          (service-extension profile-service-type
                             (const (list roguix-settings)))))
   (default-value #f)
   (description "Open the Mac app's settings from Omarchy's Setup menu.")))

;;; Touch ID for sudo: the Arch guest's broker (byte-identical copy; only its
;;; two /usr/bin OpenSSL references are pointed at the store below) asks the
;;; host over the root-only dev.tryomarchy.authentication port and verifies
;;; the Secure Enclave signature with OpenSSL.
;;;
;;; The Arch guest edits /etc/pam.d/sudo when the owner opts in. Guix generates
;;; /etc/pam.d, so sudo always carries one `sufficient' pam_exec rule, and its
;;; gate fails at once unless roguix-touch-id-control has enrolled with the
;;; host and written %touch-id-marker. Until then the rule changes nothing;
;;; afterwards any failure still falls back to the password. Enrollment comes
;;; before the marker and disabling removes the marker first, as in the Arch
;;; control script.

(define %touch-id-marker "/var/lib/roguix/touch-id-enabled")

(define roguix-touch-id
  (package
    (name "roguix-touch-id")
    (version "1")
    (source (local-file "authentication-broker"))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~'(("authentication-broker" "libexec/roguix/authentication-broker"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'use-store-openssl
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((openssl (search-input-file inputs "bin/openssl")))
                (substitute* "authentication-broker"
                  (("Path\\(\"/usr/bin/openssl\"\\)")
                   (string-append "Path(\"" openssl "\")"))
                  (("\\{\"PATH\": \"/usr/bin\"\\}")
                   (string-append "{\"PATH\": \"" (dirname openssl) "\"}"))))))
          (add-after 'install 'install-commands
            (lambda _
              (let* ((broker (string-append
                              #$output "/libexec/roguix/authentication-broker"))
                     (sh #$(file-append bash-minimal "/bin/sh"))
                     (sudo "/run/privileged/bin/sudo")
                     (gate (string-append #$output "/libexec/roguix/touch-id-gate"))
                     (control (string-append #$output "/sbin/roguix-touch-id-control"))
                     (user (string-append #$output "/bin/roguix-touch-id")))
                (define (script file text)
                  (mkdir-p (dirname file))
                  (call-with-output-file file
                    (lambda (port) (format port "#!~a~%~a" sh text)))
                  (chmod file #o555))
                (chmod broker #o555)
                (script gate (string-append "\
# pam_exec gate for sudo: inert until Touch ID was enabled.
[ -f " #$%touch-id-marker " ] || exit 1
exec " broker " pam
"))
                (script control (string-append "\
set -eu
marker=" #$%touch-id-marker "
[ \"$(id -u)\" = 0 ] || { echo 'roguix-touch-id-control: run as root' >&2; exit 1; }
case \"${1:-}\" in
  enable)
    " broker " enroll
    mkdir -p -m 0700 \"$(dirname \"$marker\")\"
    : > \"$marker\"
    chmod 0600 \"$marker\"
    echo 'Touch ID is enabled for sudo. The guest password remains available as fallback.' ;;
  disable)
    rm -f \"$marker\"
    " broker " disable
    echo 'Touch ID is disabled for sudo.' ;;
  repair)
    \"$0\" disable
    \"$0\" enable ;;
  *)
    echo 'Usage: roguix-touch-id-control enable|disable|repair' >&2
    exit 64 ;;
esac
"))
                (script user (string-append "\
# Enable or disable Touch ID for sudo; sudo asks for the password once.
exec " sudo " " control " \"$@\"
"))))))))
    (inputs (list bash-minimal openssl python-minimal))
    (home-page "https://github.com/omacom/try-omarchy")
    (synopsis "Approve sudo with the Mac's Touch ID")
    (description "Ask the Mac to approve sudo with Touch ID, verifying its
Secure Enclave signature, with the password as fallback.")
    (license license:expat)))

(define touch-id-gate
  (file-append roguix-touch-id "/libexec/roguix/touch-id-gate"))

(define (touch-id-pam-extension _)
  (list (pam-extension
         (transformer
          (lambda (service)
            (if (string=? (pam-service-name service) "sudo")
                (pam-service
                 (inherit service)
                 (auth (cons (pam-entry
                              (control "sufficient")
                              (module (file-append linux-pam
                                                   "/lib/security/pam_exec.so"))
                              (arguments (list "quiet" "seteuid" "stdout"
                                               touch-id-gate)))
                             (pam-service-auth service))))
                service))))))

(define roguix-touch-id-service-type
  (service-type
   (name 'roguix-touch-id)
   (extensions
    (list (service-extension pam-root-service-type touch-id-pam-extension)
          (service-extension udev-service-type
                             (const
                              (list (udev-rule
                                     "93-roguix-authentication.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.authentication\", OWNER=\"root\", GROUP=\"root\", MODE=\"0600\"\n"))))
          (service-extension profile-service-type
                             (const (list roguix-touch-id)))))
   (default-value #f)
   (description "Offer Touch ID approval for sudo, inert until enabled.")))
