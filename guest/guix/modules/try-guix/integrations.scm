;;; Try Guix — guest side of the launcher's macOS integrations.
;;;
;;; The host side and its wire protocols are the Arch guest's, unchanged. The
;;; guest programs are byte-identical copies of the Arch guest's reviewed
;;; scripts (test_build.py pins them); only how they are started differs:
;;; Shepherd services and login hooks instead of systemd units.
;;;
;;; The Arch guest reads launcher settings from its kernel command line. A
;;; UEFI guest boots its own GRUB, so the launcher passes the same
;;; `name=value' arguments as SMBIOS OEM strings (type 11) instead, and
;;; try-guix-host-settings writes them to %try-guix-host-settings-file in the
;;; command line's format. That file lives in /run: settings last one boot.
(define-module (try-guix integrations)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system trivial)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages pulseaudio)
  #:use-module (gnu packages python)
  #:use-module (gnu packages xdisorg)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services linux)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services ssh)
  #:export (%try-guix-host-settings-file
            try-guix-host-settings-service-type
            try-guix-mac-share
            try-guix-mac-share-service-type
            try-guix-agent
            try-guix-clipboard-bridge
            try-guix-clipboard-service-type
            try-guix-audio-bridge
            try-guix-audio-service-type
            try-guix-camera-bridge
            try-guix-camera-service-type
            try-guix-ssh-access-service-type))

(define %try-guix-host-settings-file "/run/try-guix/host-settings")

(define host-settings-program
  (program-file
   "try-guix-host-settings"
   #~(begin
       (use-modules (ice-9 binary-ports) (ice-9 ftw) (ice-9 iconv) (ice-9 regex)
                    (rnrs bytevectors) (srfi srfi-1))

       (define directory "/sys/firmware/dmi/entries")
       ;; Exactly the launcher's argument shape; anything else is ignored.
       (define setting
         (make-regexp "^(omarchy|tryomarchy)\\.[a-z_]+=[A-Za-z0-9_-]*$"))

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
                     "try-guix-host-settings: ignoring SMBIOS: ~a ~s~%"
                     key arguments)
             '())))

       (define target #$%try-guix-host-settings-file)
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
         (provision '(try-guix-host-settings))
         (requirement '(file-systems))
         (one-shot? #t)
         (documentation "Record the launcher's settings for this boot.")
         (start #~(lambda _
                    (zero? (system* #$host-settings-program)))))))

(define try-guix-host-settings-service-type
  (service-type
   (name 'try-guix-host-settings)
   (extensions (list (service-extension shepherd-root-service-type
                                        host-settings-shepherd-service)))
   (default-value #f)
   (description "Write the launcher's SMBIOS OEM settings to /run/try-guix.")))

;;; Shared folder: the launcher attaches virtio-9p with mount tag `mac' and
;;; passes the folder's name as omarchy.shared_folder_name. The mount runs as
;;; root before tty1 logs in; each login of the desktop account links ~/<name>.

(define try-guix-mac-share
  (package
    (name "try-guix-mac-share")
    (version "1")
    (source (local-file "mac-share"))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan #~'(("mac-share" "bin/try-guix-mac-share"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'wrap
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((program (string-append #$output "/bin/try-guix-mac-share")))
                (chmod program #o555)
                (wrap-program program
                  `("OMARCHY_MAC_SHARE_CMDLINE" = (#$%try-guix-host-settings-file))
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
  (file-append try-guix-mac-share "/bin/try-guix-mac-share"))

(define (mac-share-shepherd-service _)
  (list (shepherd-service
         (provision '(try-guix-mac-share))
         (requirement '(file-systems udev kernel-module-loader
                        try-guix-host-settings))
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
  (mixed-text-file "try-guix-mac-share-link.sh"
                   "if [ \"$(id -u)\" = 1000 ]; then\n  "
                   mac-share-program " --link 2>/dev/null || true\nfi\n"))

(define try-guix-mac-share-service-type
  (service-type
   (name 'try-guix-mac-share)
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
;;; with Restart=. Hyprland starts each one here through try-guix-agent, which
;;; runs it while this compositor's socket and the bridge's virtio port exist,
;;; and restarts it 2 s after it exits (the bridges exit when the host side
;;; disconnects). Agents therefore end with the session.

(define try-guix-agent
  (package
    (name "try-guix-agent")
    (version "1")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((program (string-append #$output "/bin/try-guix-agent")))
            (mkdir-p (dirname program))
            (call-with-output-file program
              (lambda (port)
                (format port "#!~a
# try-guix-agent PORT PROGRAM...: keep PROGRAM running for this session.
[ -n \"$WAYLAND_DISPLAY\" ] || { echo 'try-guix-agent: no Wayland session' >&2; exit 1; }
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
    (synopsis "Restart a Try Guix bridge for the life of the session")
    (description "Run a host bridge while the Wayland session and its virtio
port exist, restarting it after it exits.")
    (license license:expat)))

;; An Arch guest script whose #!/usr/bin/python3 becomes Guix's Python and
;; whose tools are put on PATH. SOURCE is (local-file FILE), written at the
;; call site so it resolves next to this module.
(define* (arch-guest-python-script name file source #:key (tools '())
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

(define try-guix-clipboard-bridge
  (arch-guest-python-script "try-guix-clipboard-bridge" "clipboard-bridge"
                            (local-file "clipboard-bridge")
                            #:tools '("bin/wl-paste")
                            #:inputs (list wl-clipboard)
                            #:synopsis "Share the Wayland clipboard with macOS"))

(define try-guix-clipboard-service-type
  (service-type
   (name 'try-guix-clipboard)
   (extensions
    (list (service-extension udev-service-type
                             (const
                              (list (udev-rule
                                     "92-try-guix-clipboard.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.clipboard\", GROUP=\"users\", MODE=\"0660\"\n"))))
          (service-extension profile-service-type
                             (const (list try-guix-agent
                                          try-guix-clipboard-bridge
                                          wl-clipboard)))))
   (default-value #f)
   (description "Install the clipboard bridge and its port permissions.")))

;;; SSH: the launcher adds tryomarchy.ssh_access=1 only while a forward to
;;; guest port 22 is configured. sshd is installed but never auto-started;
;;; this one-shot starts it for the current boot when that exact setting is
;;; present, and nothing is written for later boots.

(define (ssh-access-shepherd-service _)
  (list (shepherd-service
         (provision '(try-guix-ssh-access))
         (requirement '(try-guix-host-settings))
         (one-shot? #t)
         (documentation "Start sshd when the launcher forwards SSH.")
         (start #~(lambda _
                    (let ((settings
                           (false-if-exception
                            (call-with-input-file #$%try-guix-host-settings-file
                              (@ (ice-9 rdelim) read-line)))))
                      (when (and (string? settings)
                                 (member "tryomarchy.ssh_access=1"
                                         (string-tokenize settings)))
                        (start-service (lookup-service 'ssh-daemon)))
                      #t))))))

(define try-guix-ssh-access-service-type
  (service-type
   (name 'try-guix-ssh-access)
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

(define try-guix-audio-bridge
  (arch-guest-python-script "try-guix-audio-bridge" "audio-bridge"
                            (local-file "audio-bridge")
                            #:tools '("bin/pactl")
                            #:inputs (list pulseaudio)
                            #:synopsis "Expose macOS audio devices to PipeWire"))

(define try-guix-audio-service-type
  (service-type
   (name 'try-guix-audio)
   (extensions
    (list (service-extension udev-service-type
                             (const
                              (list (udev-rule
                                     "91-try-guix-audio.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.audio\", GROUP=\"audio\", MODE=\"0660\"\n"))))
          (service-extension etc-service-type
                             (const
                              `(("pipewire/pipewire.conf.d/90-try-omarchy-quantum.conf"
                                 ,(local-file "pipewire-quantum.conf")))))
          (service-extension profile-service-type
                             (const (list pipewire wireplumber pulseaudio
                                          try-guix-agent
                                          try-guix-audio-bridge)))))
   (default-value #f)
   (description "Run PipeWire per session with the macOS audio bridge.")))

;;; Camera: the Mac camera streams 1280x720 NV12 frames over
;;; dev.tryomarchy.camera only while a Linux program reads /dev/video42, a
;;; v4l2loopback device (operating-system kernel-loadable-modules must list
;;; v4l2loopback-linux-module). Module options are the Arch guest's.

(define try-guix-camera-bridge
  (arch-guest-python-script "try-guix-camera-bridge" "camera-bridge"
                            (local-file "camera-bridge")
                            #:synopsis "Expose the macOS camera as /dev/video42"))

(define try-guix-camera-service-type
  (service-type
   (name 'try-guix-camera)
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
                                     "94-try-guix-camera.rules"
                                     "SUBSYSTEM==\"virtio-ports\", ATTR{name}==\"dev.tryomarchy.camera\", GROUP=\"video\", MODE=\"0660\"
KERNEL==\"video42\", SUBSYSTEM==\"video4linux\", GROUP=\"video\", MODE=\"0660\"\n"))))
          (service-extension profile-service-type
                             (const (list try-guix-agent
                                          try-guix-camera-bridge)))))
   (default-value #f)
   (description "Load v4l2loopback and install the macOS camera bridge.")))
