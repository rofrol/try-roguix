;; Development guest for the existing ARM64 Virtio/VirGL QEMU runtime.
(use-modules (gnu)
             (gnu system linux-initrd)
             (ice-9 regex)
             (srfi srfi-1)
             (try-guix packages)
             (try-guix services))
(use-service-modules desktop sddm xorg)
(use-package-modules fonts gl linux terminals window-management xdisorg)

;; Never ship a shared default password or enable passwordless sudo.  This
;; development image contains the supplied hash in its store closure: use a
;; throwaway password and do not distribute the resulting image.
(define guest-password
  (let ((value (getenv "GUIX_GUEST_PASSWORD_HASH")))
    (unless (and value
                 (string-match "^\\$6\\$[./0-9A-Za-z]{1,16}\\$[./0-9A-Za-z]{86}$"
                               value))
      (error "Set GUIX_GUEST_PASSWORD_HASH to a SHA-512 crypt hash"))
    value))

;; Files that define this system; build and test tooling is left out.
(define (try-guix-source? file stat)
  (let ((name (basename file)))
    (or (eq? 'directory (stat:type stat))
        (member name '("system.scm" "hyprland.lua" "packages.scm" "services.scm"
                       "display-sync" "hyprland-rounded-border-coverage.patch")))))

(operating-system
  (host-name "try-guix")
  (timezone "Etc/UTC")
  (locale "en_US.utf8")
  (keyboard-layout (keyboard-layout "us"))
  (kernel linux-libre)
  (firmware '())
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
                (user-account
                 (name "guest")
                 (uid 1000)
                 (group "users")
                 (password guest-password)
                 (supplementary-groups '("wheel" "netdev" "audio" "video")))
                %base-user-accounts))

  ;; Foot avoids the separate Kitty OpenGL-context workaround in the Arch
  ;; guest. Keep compositor rendering on VirGL, without a software override.
  (packages (append (list hyprland-0.56 try-guix-display-sync
                          foot wofi font-dejavu mesa-utils)
                    %base-packages))
  (services
   (cons* ;; The same definitions for in-guest reconfigure and rollback, so they
          ;; never fall back to the pinned checkout's broken Hyprland 0.55.4:
          ;;   sudo guix system reconfigure -L /etc/try-guix/modules \
          ;;     /etc/try-guix/system.scm
          (simple-service 'try-guix-sources etc-service-type
                          `(("try-guix"
                             ,(local-file "." "try-guix-sources"
                                          #:recursive? #t
                                          #:select? try-guix-source?))))
          (simple-service 'try-guix-hyprland account-service-type
                          `((".config/hypr/hyprland.lua"
                             ,(local-file "hyprland.lua"))))
          (service try-guix-grow-root-service-type)
          (service sddm-service-type)
          (remove (lambda (service)
                    (memq (service-kind service)
                          (list gdm-service-type sddm-service-type)))
                  %desktop-services))))
