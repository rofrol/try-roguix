;;; Roguix — the guest's operating system.
;;;
;;; `roguix-operating-system' is the whole system; guest/guix/system.scm
;;; builds the image from it with no extra packages. In the guest,
;;; /etc/config.scm calls it with the owner's package list (edited by hand or
;;; by Omarchy's install menus through roguix-pkg), and
;;; `sudo roguix-reconfigure' applies it with the Guix that built the image.
(define-module (roguix system)
  #:use-module (gnu)
  #:use-module (gnu system linux-initrd)
  #:use-module (guix gexp)
  #:use-module (guix grafts)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (roguix integrations)
  #:use-module (roguix omarchy)
  #:use-module (roguix packages)
  #:use-module (roguix services)
  #:export (roguix-operating-system
            %pinned-guix-root))
(use-service-modules desktop sddm sound ssh xorg)
(use-package-modules fonts gl linux package-management terminals
                     window-management xdisorg)

;; The Guix that evaluated the system. Building the image, that is the pinned
;; commit run by `guix time-machine'; the image keeps it as a GC root, and in
;; the guest the system reuses that same store item instead of rebuilding it,
;; so reconfiguring with it computes the very derivations the image was built
;; from and only fetches what the owner adds.
(define %pinned-guix-root "/var/guix/gcroots/roguix-guix")
(define (pinned-guix)
  (if (file-exists? %pinned-guix-root)
      (readlink %pinned-guix-root)
      (current-guix)))

;; Files that define this system; build and test tooling is left out.
(define (roguix-source? file stat)
  (or (eq? 'directory (stat:type stat))
      (member (basename file) '("system.scm"))
      (string-contains file "/modules/roguix/")))

;; Installed as /etc/config.scm on first boot, then the owner's to edit.
(define config-template
  (plain-file "config.scm" "\
;; Roguix: this machine's system configuration.
;;
;; Add programs by their Guix package names (`guix search NAME' finds them),
;; then apply the change with:
;;
;;   sudo roguix-reconfigure
;;
;; Omarchy's install menus edit the same list. Everything else is the Roguix
;; system in /etc/roguix, which this reuses as is.
(use-modules (roguix system))

(roguix-operating-system
 #:packages
 '(;; BEGIN roguix packages
   ;; END roguix packages
   ))
"))

(define roguix-config-activation
  #~(unless (file-exists? "/etc/config.scm")
      (copy-file #$config-template "/etc/config.scm")
      (chmod "/etc/config.scm" #o644)))

;; Guix builds every package first without grafts (its security fixes applied
;; to finished binaries) and then grafts it. The image holds only grafted
;; items, so a reconfigure, which grafts again, would rebuild Roguix's own
;; packages (Hyprland, Quickshell), which have no substitutes, and download
;; the ungrafted Guix packages. The image therefore keeps the whole ungrafted
;; system as a GC root.
(define %ungrafted-root "/var/guix/gcroots/roguix-ungrafted")

;; An operating system as a file-like object: its system derivation's output.
(define-record-type <system-closure>
  (system-closure os)
  system-closure?
  (os system-closure-os))

(define-gexp-compiler (system-closure-compiler (closure <system-closure>)
                                               system target)
  (operating-system-derivation (system-closure-os closure)))

(define* (roguix-operating-system #:key (packages '()))
  "Return the Roguix system, adding PACKAGES, a list of package names."
  (let ((os (base-operating-system packages)))
    (operating-system
      (inherit os)
      (services
       (cons (extra-special-file %ungrafted-root
                                 (with-parameters ((%graft? #f))
                                   (system-closure os)))
             (operating-system-user-services os))))))

(define (base-operating-system packages)
  (operating-system
    (host-name "roguix")
    (timezone "Etc/UTC")
    (locale "en_US.utf8")
    (keyboard-layout (keyboard-layout "us"))
    (kernel linux-libre)
    (firmware '())
    ;; /dev/video42 for the Mac camera (roguix-camera-service-type).
    (kernel-loadable-modules (list v4l2loopback-linux-module))
    (initrd-modules (cons* "virtio_gpu" "virtio_console"
                           (base-initrd-modules linux-libre)))
    (kernel-arguments (cons "console=hvc0" %default-kernel-arguments))

    ;; The launcher boots EDK2 with -bios, which keeps no UEFI variables, so
    ;; GRUB must live at the removable-media path EFI/BOOT/BOOTAA64.EFI; every
    ;; reconfigure reinstalls it there.
    (bootloader (bootloader-configuration
                  (bootloader grub-efi-removable-bootloader)
                  (targets '("/boot/efi"))))
    ;; The image itself mounts / by a UUID that `guix system image` derives; this
    ;; label is what that partition's ext4 carries, so an in-guest reconfigure
    ;; of this file finds the same root.
    (file-systems
     (cons* (file-system
              (mount-point "/")
              (device (file-system-label "Guix_image"))
              (type "ext4"))
            (file-system
              (mount-point "/boot/efi")
              (device (file-system-label "GNU-ESP"))
              (type "vfat"))
            %base-file-systems))

    (users (cons* (user-account
                   (name "root")
                   (uid 0)
                   (group "root")
                   (home-directory "/root")
                   (password "!"))
                  ;; No password ships in the image: the account starts locked
                  ;; and roguix-first-boot asks for one on the first start.
                  (user-account
                   (name %roguix-account)
                   (uid 1000)
                   (group "users")
                   (password "!")
                   (supplementary-groups '("wheel" "netdev" "audio" "video")))
                  %base-user-accounts))

    ;; Foot avoids the separate Kitty OpenGL-context workaround in the Arch
    ;; guest. Keep compositor rendering on VirGL, without a software override.
    (packages (append (list hyprland-0.56 roguix-display-sync
                            foot wofi font-dejavu mesa-utils)
                      (map specification->package packages)
                      %base-packages))
    (services
     (cons* ;; The same definitions for in-guest reconfigure and rollback, so they
            ;; never fall back to the pinned checkout's broken Hyprland 0.55.4:
            ;;   sudo guix system reconfigure -L /etc/roguix/modules \
            ;;     /etc/roguix/system.scm
            (simple-service 'roguix-sources etc-service-type
                            `(("roguix"
                               ,(local-file "../.." "roguix-sources"
                                            #:recursive? #t
                                            #:select? roguix-source?))))
            ;; Omarchy 4's desktop: its Hyprland configuration and Quickshell
            ;; shell, seeded into the account at the first desktop login.
            (service roguix-omarchy-service-type)
            (service roguix-grow-root-service-type)
            (extra-special-file %pinned-guix-root (pinned-guix))
            (simple-service 'roguix-config activation-service-type
                            roguix-config-activation)
            (service roguix-first-boot-service-type)
            (service roguix-host-settings-service-type)
            (service roguix-mac-share-service-type)
            (service roguix-clipboard-service-type)
            (service roguix-audio-service-type)
            (service roguix-camera-service-type)
            (service roguix-touch-id-service-type)
            ;; Installed but never auto-started: roguix-ssh-access starts it
            ;; for one boot when the launcher forwards SSH.
            (service openssh-service-type
                     (openssh-configuration
                      (%auto-start? #f)
                      (permit-root-login #f)))
            (service roguix-ssh-access-service-type)
            ;; Like the Arch guest, log straight in on the VM console: the disk
            ;; is protected by the Mac account. tty1 waits for the first-start
            ;; password prompt, then /etc/profile.d starts Hyprland there.
            (simple-service 'roguix-session etc-profile-d-service-type
                            (list roguix-session-script))
            (modify-services
                (remove (lambda (service)
                          (memq (service-kind service)
                                (list gdm-service-type sddm-service-type)))
                        %desktop-services)
              ;; pipewire-pulse serves the PulseAudio socket; pactl (the audio
              ;; bridge's tool) must never start a real PulseAudio daemon.
              (pulseaudio-service-type
               config => (pulseaudio-configuration
                          (inherit config)
                          (client-conf '((autospawn . no)))))
              (mingetty-service-type
               config => (if (string=? (mingetty-configuration-tty config) "tty1")
                             (mingetty-configuration
                              (inherit config)
                              (auto-login %roguix-account)
                              ;; The shared folder is mounted before the
                              ;; session starts, as in the Arch guest. The
                              ;; login also waits for Shepherd's elogind:
                              ;; pam_elogind would otherwise D-Bus-activate a
                              ;; second one, Shepherd would disable its own,
                              ;; and everything requiring elogind (pam, sshd)
                              ;; could no longer start.
                              (shepherd-requirement
                               (cons* 'roguix-first-boot 'roguix-mac-share
                                      'elogind
                                      (mingetty-configuration-shepherd-requirement
                                       config))))
                             config)))))))
