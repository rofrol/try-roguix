;; Development guest for the existing ARM64 Virtio/VirGL QEMU runtime.
(use-modules (gnu)
             (gnu system linux-initrd)
             (srfi srfi-1)
             (try-guix integrations)
             (try-guix packages)
             (try-guix services))
(use-service-modules desktop sddm ssh xorg)
(use-package-modules fonts gl linux terminals window-management xdisorg)

;; Files that define this system; build and test tooling is left out.
(define (try-guix-source? file stat)
  (or (eq? 'directory (stat:type stat))
      (member (basename file) '("system.scm" "hyprland.lua"))
      (string-contains file "/modules/try-guix/")))

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
                ;; No password ships in the image: the account starts locked
                ;; and try-guix-first-boot asks for one on the first start.
                (user-account
                 (name %try-guix-account)
                 (uid 1000)
                 (group "users")
                 (password "!")
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
          (service try-guix-first-boot-service-type)
          (service try-guix-host-settings-service-type)
          (service try-guix-mac-share-service-type)
          (service try-guix-clipboard-service-type)
          ;; Installed but never auto-started: try-guix-ssh-access starts it
          ;; for one boot when the launcher forwards SSH.
          (service openssh-service-type
                   (openssh-configuration
                    (%auto-start? #f)
                    (permit-root-login #f)))
          (service try-guix-ssh-access-service-type)
          ;; Like the Arch guest, log straight in on the VM console: the disk
          ;; is protected by the Mac account. tty1 waits for the first-start
          ;; password prompt, then /etc/profile.d starts Hyprland there.
          (simple-service 'try-guix-session etc-profile-d-service-type
                          (list try-guix-session-script))
          (modify-services
              (remove (lambda (service)
                        (memq (service-kind service)
                              (list gdm-service-type sddm-service-type)))
                      %desktop-services)
            (mingetty-service-type
             config => (if (string=? (mingetty-configuration-tty config) "tty1")
                           (mingetty-configuration
                            (inherit config)
                            (auto-login %try-guix-account)
                            ;; The shared folder is mounted before the
                            ;; session starts, as in the Arch guest. The
                            ;; login also waits for Shepherd's elogind:
                            ;; pam_elogind would otherwise D-Bus-activate a
                            ;; second one, Shepherd would disable its own,
                            ;; and everything requiring elogind (pam, sshd)
                            ;; could no longer start.
                            (shepherd-requirement
                             (cons* 'try-guix-first-boot 'try-guix-mac-share
                                    'elogind
                                    (mingetty-configuration-shepherd-requirement
                                     config))))
                           config))))))
