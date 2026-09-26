;;; Roguix — services for the launcher's persistent UEFI/GPT disk and the
;;; first start of a new VM.
;;;
;;; roguix-grow-root: the host grows a VM disk only by extending the file.
;;; At boot this service moves the backup GPT to the new end of the disk,
;;; extends the root partition over the free space and grows its ext4 file
;;; system online. It keeps the partition's start, type, GUID and name.
;;;
;;; roguix-first-boot: the image carries no password. The account is
;;; declared locked, and on the first start this service asks for its password
;;; on tty1 before the console logs in automatically. Account activation keeps
;;; a password set this way across reboots and reconfigures.
(define-module (roguix services)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module ((roguix integrations)
                #:select (%roguix-host-settings-file roguix-setup))
  #:use-module (gnu packages bash)
  #:export (%roguix-account
            roguix-grow-root-service-type
            roguix-first-boot-service-type
            roguix-session-script))

;; The single desktop account: uid 1000, which the launcher's shared-folder
;; mapping also assumes.
(define %roguix-account "guest")

;; Also the root file system label in system.scm; `guix system image` gives the
;; root partition and its ext4 this label.
(define %root-label "Guix_image")

(define grow-root-program
  (program-file
   "roguix-grow-root"
   #~(begin
       (use-modules (ice-9 popen) (ice-9 rdelim) (ice-9 regex))

       (define (sysfs-number file)
         (string->number (call-with-input-file file read-line)))

       (define (run program . arguments)
         (unless (zero? (apply system* program arguments))
           (error "command failed" program arguments)))

       (let* ((root (canonicalize-path
                     (string-append "/dev/disk/by-label/" #$%root-label)))
              (match (string-match "^/dev/(vd[a-z]+)([0-9]+)$" root)))
         ;; Only the launcher's virtio disk layout: partition 2 of /dev/vdX.
         (unless (and match (string=? (match:substring match 2) "2"))
           (error "unexpected root device" root))
         (let* ((disk-name (match:substring match 1))
                (disk (string-append "/dev/" disk-name))
                (sysfs (string-append "/sys/block/" disk-name "/"))
                (part (string-append sysfs disk-name "2/"))
                (disk-sectors (sysfs-number (string-append sysfs "size")))
                (part-end (+ (sysfs-number (string-append part "start"))
                             (sysfs-number (string-append part "size"))))
                ;; 33 sectors hold the backup GPT; ignore sub-MiB slack.
                (free (- disk-sectors part-end 33)))
           (when (>= free 2048)
             (format #t "Growing ~a over ~a free sectors~%" root free)
             (run #$(file-append util-linux "/sbin/sfdisk")
                  "--relocate" "gpt-bak-std" disk)
             (let ((port (open-pipe* OPEN_WRITE
                                     #$(file-append util-linux "/sbin/sfdisk")
                                     "--no-reread" "--no-tell-kernel"
                                     "-N" "2" disk)))
               (display ",+\n" port)
               (unless (zero? (status:exit-val (close-pipe port)))
                 (error "sfdisk could not extend the root partition")))
             (run #$(file-append util-linux "/sbin/partx")
                  "--update" "--nr" "2" disk))
           ;; Idempotent, and completes a growth interrupted after sfdisk.
           (run #$(file-append e2fsprogs "/sbin/resize2fs") root))))))

(define (grow-root-shepherd-service _)
  (list (shepherd-service
         (provision '(roguix-grow-root))
         (requirement '(file-systems udev))
         (one-shot? #t)
         (documentation "Grow the root partition and file system to the disk.")
         (start #~(lambda _
                    (zero? (system* #$grow-root-program)))))))

(define roguix-grow-root-service-type
  (service-type
   (name 'roguix-grow-root)
   (extensions (list (service-extension shepherd-root-service-type
                                        grow-root-shepherd-service)))
   (default-value #f)
   (description "Grow the root partition and ext4 file system at boot.")))

(define first-boot-program
  (program-file
   "roguix-first-boot"
   #~(begin
       (use-modules (ice-9 rdelim))

       (define prefix (string-append #$%roguix-account ":"))

       (define (locked?)
         ;; Declared with the locked password "!"; anything else was set by
         ;; roguix-setup or by the owner later.
         (call-with-input-file "/etc/shadow"
           (lambda (port)
             (let loop ()
               (let ((line (read-line port)))
                 (cond ((eof-object? line) #f)
                       ((string-prefix? prefix line)
                        (string-prefix? "!" (substring line (string-length prefix))))
                       (else (loop))))))))

       ;; roguix-setup asks on tty1 as its controlling terminal; asked again
       ;; until the password is set, so an interrupted setup starts over.
       (setenv "TERM" "linux")
       (let loop ((attempts 0))
         (when (and (locked?) (< attempts 50))
           (system* #$(file-append util-linux "/bin/setsid") "-w" "-c"
                    #$(file-append bash-minimal "/bin/sh") "-c"
                    (string-append "exec " #$(file-append roguix-setup
                                                          "/bin/roguix-setup")
                                   " <>/dev/tty1 >&0 2>&0"))
           (loop (+ attempts 1)))))))

(define (first-boot-shepherd-service _)
  (list (shepherd-service
         (provision '(roguix-first-boot))
         ;; The Mac's suggestions arrive through roguix-host-settings.
         (requirement '(file-systems roguix-host-settings))
         (one-shot? #t)
         (documentation "Ask the first-start setup questions on tty1.")
         (start #~(lambda _
                    (zero? (system* #$first-boot-program)))))))

(define roguix-first-boot-service-type
  (service-type
   (name 'roguix-first-boot)
   (extensions (list (service-extension shepherd-root-service-type
                                        first-boot-shepherd-service)))
   (default-value #f)
   (description "Ask for the desktop account's password on the first start.")))

;; For etc-profile-d-service-type: the auto-login console seeds Omarchy's
;; user files once (roguix-omarchy-seed) and runs the compositor inside its
;; own D-Bus session bus (PipeWire's WirePlumber and desktop
;; programs expect one); other consoles, the serial console and SSH get an
;; ordinary shell.
(define roguix-session-script
  (mixed-text-file "roguix-session.sh" "\
if [ \"$(tty)\" = /dev/tty1 ] && [ -z \"$WAYLAND_DISPLAY\" ] \\
   && [ \"$(id -un)\" = " %roguix-account " ]; then
  # Omarchy's per-user files; a failure still starts the desktop.
  roguix-omarchy-seed || echo 'roguix: seeding Omarchy failed' >&2
  # Omarchy's environment.d for its input method; no systemd reads it here.
  set -a
  . /usr/share/omarchy/default/environment.d/10-omarchy-fcitx.conf
  set +a
  # The launcher's optional guest language (roguix-host-settings).
  case \" $(cat " %roguix-host-settings-file " 2>/dev/null) \" in
    *' tryomarchy.locale=zh_TW.UTF-8 '*) export LANG=zh_TW.UTF-8 ;;
  esac
  exec " (file-append dbus "/bin/dbus-run-session") " start-hyprland
fi
"))
