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
  #:use-module (gnu system locale)
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix grafts)
  #:use-module (guix monads)
  #:use-module ((guix store) #:select (%store-monad))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (roguix integrations)
  #:use-module (roguix omarchy)
  #:use-module (roguix packages)
  #:use-module (roguix services)
  #:export (roguix-operating-system
            %pinned-guix-root))
(use-service-modules desktop docker sddm sound ssh xorg)
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

;; Substitutes for Roguix's packages: guix publish on the author's server
;; (docs/decisions/0002-roguix-substitute-server.md).
(define %roguix-substitute-url "https://roguix.frolow.dev")

;; An operating system as a file-like object: its system derivation's output.
(define-record-type <system-closure>
  (system-closure os)
  system-closure?
  (os system-closure-os))

(define-gexp-compiler (system-closure-compiler (closure <system-closure>)
                                               system target)
  (operating-system-derivation (system-closure-os closure)))

;; A graft derivation produces every output of the package it grafts, but the
;; image holds only the outputs the system refers to. A VM's first reconfigure
;; then found such grafts incomplete (glib:debug, glibc:static, ...), fetched
;; the ungrafted outputs and grafted most of the system again, for about half
;; an hour. The image therefore keeps every output of the system's grafts.
(define %graft-outputs-root "/var/guix/gcroots/roguix-graft-outputs")

(define-record-type <graft-outputs>
  (graft-outputs os)
  graft-outputs?
  (os graft-outputs-os))

(define (graft? drv)
  (eq? 'graft (assq-ref (derivation-properties drv) 'type)))

(define (local-build? drv)
  (equal? "1" (assoc-ref (derivation-builder-environment-vars drv)
                         "preferLocalBuild")))

(define (system-grafts drv)
  "Return the graft derivations DRV, a system derivation, depends on. Only
grafts and the system's own local derivations are searched; package builds
below them are not."
  (let loop ((todo (list drv)) (seen (make-hash-table)) (grafts '()))
    (match todo
      (() grafts)
      ((current . rest)
       (let ((file (derivation-file-name current)))
         (if (or (hash-ref seen file)
                 (not (or (eq? current drv) (graft? current)
                          (local-build? current))))
             (loop rest seen grafts)
             (begin
               (hash-set! seen file #t)
               (loop (append (map derivation-input-derivation
                                  (derivation-inputs current))
                             rest)
                     seen
                     (if (graft? current) (cons current grafts) grafts)))))))))

(define-gexp-compiler (graft-outputs-compiler (roots <graft-outputs>)
                                              system target)
  (mlet %store-monad ((drv (operating-system-derivation
                            (graft-outputs-os roots))))
    (let ((outputs (append-map (lambda (graft)
                                 (map (lambda (output)
                                        (gexp-input graft (car output)))
                                      (derivation-outputs graft)))
                               (system-grafts drv))))
      (gexp->derivation "roguix-graft-outputs"
                        #~(begin
                            (mkdir #$output)
                            (let loop ((items (list #$@outputs)) (index 0))
                              (unless (null? items)
                                (symlink (car items)
                                         (string-append #$output "/"
                                                        (number->string index)))
                                (loop (cdr items) (+ index 1)))))
                        #:local-build? #t))))

(define* (roguix-operating-system #:key (packages '()))
  "Return the Roguix system, adding PACKAGES, a list of package names."
  (let ((os (base-operating-system packages)))
    (operating-system
      (inherit os)
      (services
       (cons* (extra-special-file %ungrafted-root
                                  (with-parameters ((%graft? #f))
                                    (system-closure os)))
              (extra-special-file %graft-outputs-root (graft-outputs os))
              (operating-system-user-services os))))))

(define (base-operating-system packages)
  (operating-system
    (host-name "roguix")
    (timezone "Etc/UTC")
    (locale "en_US.utf8")
    ;; Traditional Chinese, the launcher's one optional guest language
    ;; (tryomarchy.locale); the session sets LANG from it.
    (locale-definitions
     (cons (locale-definition (name "zh_TW.utf8") (source "zh_TW")
                              (charset "UTF-8"))
           %default-locale-definitions))
    (keyboard-layout (keyboard-layout "us"))
    (kernel linux-libre)
    (firmware '())
    ;; /dev/video42 for the Mac camera (roguix-camera-service-type) and the
    ;; mirrored Mac battery (roguix-battery-service-type).
    (kernel-loadable-modules (list v4l2loopback-linux-module
                                   roguix-battery-module))
    (initrd-modules (cons* "virtio_gpu" "virtio_console"
                           (base-initrd-modules linux-libre)))
    ;; The VM's display is Retina-sized: the kernel's 8x16 console font is
    ;; unreadably small there, so boot messages use its built-in Terminus
    ;; 16x32 (see also console-font-service-type below).
    ;; The launcher sizes the display to the window's Retina pixels, where
    ;; Terminus 16x32 is small; at 1920x1080 scaled up it was too large. The
    ;; text console uses 2560x1440, outside the EDID's list, so M asks the
    ;; kernel for CVT timings. Hyprland sets its own mode from the window
    ;; (roguix-display-sync).
    (kernel-arguments (cons* "console=hvc0" "fbcon=font:TER16x32"
                             "video=Virtual-1:2560x1440M"
                             %default-kernel-arguments))

    ;; The launcher boots EDK2 with -bios, which keeps no UEFI variables, so
    ;; GRUB must live at the removable-media path EFI/BOOT/BOOTAA64.EFI; every
    ;; reconfigure reinstalls it there.
    (bootloader (bootloader-configuration
                  (bootloader grub-efi-removable-bootloader)
                  (targets '("/boot/efi"))
                  ;; At the display's native size GRUB's text is tiny; QEMU
                  ;; scales this mode up to the window.
                  ;; The inherited background is an SVG converted with
                  ;; guile-rsvg (librsvg, Rust): check it has substitutes when
                  ;; moving the pin (guest/guix/README.md).
                  (theme (grub-theme
                          (inherit (grub-theme))
                          (gfxmode '("1024x768" "auto"))))))
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
            (service roguix-battery-service-type)
            (service roguix-settings-service-type)
            (service roguix-touch-id-service-type)
            ;; Installed but never auto-started: roguix-ssh-access starts it
            ;; for one boot when the launcher forwards SSH.
            (service openssh-service-type
                     (openssh-configuration
                      (%auto-start? #f)
                      (permit-root-login #f)))
            (service roguix-ssh-access-service-type)
            ;; Omarchy's Docker: the daemon runs, but the account is not in the
            ;; docker group (root-equivalent), so the CLI runs under sudo.
            (service containerd-service-type)
            (service docker-service-type)
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
              ;; Roguix's own packages (Hyprland, Quickshell, Omarchy, the
              ;; VM agents) have no substitutes on Guix's servers; its server
              ;; publishes them, signed with roguix.frolow.dev.pub, after
              ;; Guix's own servers in the search order.
              (guix-service-type
               config => (guix-configuration
                          (inherit config)
                          (substitute-urls
                           (append (guix-configuration-substitute-urls config)
                                   (list %roguix-substitute-url)))
                          (authorized-keys
                           (cons (local-file "roguix.frolow.dev.pub")
                                 (guix-configuration-authorized-keys config)))))
              ;; pipewire-pulse serves the PulseAudio socket; pactl (the audio
              ;; bridge's tool) must never start a real PulseAudio daemon.
              ;; The Mac's own low-power handling is the only authority: UPower
              ;; still warns, but its action threshold of 0% never suspends or
              ;; powers off the VM (this UPower has no Ignore action).
              (upower-service-type
               config => (upower-configuration
                          (inherit config)
                          (use-percentage-for-policy? #t)
                          (percentage-action 0)))
              (pulseaudio-service-type
               config => (pulseaudio-configuration
                          (inherit config)
                          (client-conf '((autospawn . no)))))
              ;; Terminus 32 px on the text consoles, as for boot messages.
              (console-font-service-type
               config => (map (lambda (tty)
                                (cons (car tty)
                                      (file-append
                                       font-terminus
                                       "/share/consolefonts/ter-v32n.psf.gz")))
                              config))
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
