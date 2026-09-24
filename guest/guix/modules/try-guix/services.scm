;;; Try Guix — services for the launcher's persistent UEFI/GPT disk and the
;;; first start of a new VM.
;;;
;;; try-guix-grow-root: the host grows a VM disk only by extending the file.
;;; At boot this service moves the backup GPT to the new end of the disk,
;;; extends the root partition over the free space and grows its ext4 file
;;; system online. It keeps the partition's start, type, GUID and name.
;;;
;;; try-guix-first-boot: the image carries no password. The account is
;;; declared locked, and on the first start this service asks for its password
;;; on tty1 before the console logs in automatically. Account activation keeps
;;; a password set this way across reboots and reconfigures.
(define-module (try-guix services)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:export (%try-guix-account
            try-guix-grow-root-service-type
            try-guix-first-boot-service-type
            try-guix-session-script))

;; The single desktop account: uid 1000, which the launcher's shared-folder
;; mapping also assumes.
(define %try-guix-account "guest")

;; Also the root file system label in system.scm; `guix system image` gives the
;; root partition and its ext4 this label.
(define %root-label "Guix_image")

(define grow-root-program
  (program-file
   "try-guix-grow-root"
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
         (provision '(try-guix-grow-root))
         (requirement '(file-systems udev))
         (one-shot? #t)
         (documentation "Grow the root partition and file system to the disk.")
         (start #~(lambda _
                    (zero? (system* #$grow-root-program)))))))

(define try-guix-grow-root-service-type
  (service-type
   (name 'try-guix-grow-root)
   (extensions (list (service-extension shepherd-root-service-type
                                        grow-root-shepherd-service)))
   (default-value #f)
   (description "Grow the root partition and ext4 file system at boot.")))

(define first-boot-program
  (program-file
   "try-guix-first-boot"
   #~(begin
       (use-modules (ice-9 popen) (ice-9 rdelim))

       (define tty "/dev/tty1")
       (define prefix (string-append #$%try-guix-account ":"))

       (define (locked?)
         ;; Declared with the locked password "!"; anything else was set here
         ;; or by the owner later.
         (call-with-input-file "/etc/shadow"
           (lambda (port)
             (let loop ()
               (let ((line (read-line port)))
                 (cond ((eof-object? line) #f)
                       ((string-prefix? prefix line)
                        (string-prefix? "!" (substring line (string-length prefix))))
                       (else (loop))))))))

       (define (stty . arguments)
         (apply system* #$(file-append coreutils "/bin/stty") "-F" tty arguments))

       (define (set-password! password)
         (let ((pipe (open-pipe* OPEN_WRITE
                                 #$(file-append shadow "/sbin/chpasswd")
                                 "--crypt-method" "SHA512")))
           (display (string-append prefix password "\n") pipe)
           (zero? (status:exit-val (close-pipe pipe)))))

       (when (locked?)
         (let ((port (open-file tty "r+")))
           (define (say . strings)
             (for-each (lambda (text) (display text port)) strings)
             (force-output port))
           (define (ask prompt)
             (say prompt)
             (stty "-echo")
             (let ((line (read-line port)))
               (stty "echo")
               (say "\n")
               (if (eof-object? line) "" line)))
           (say "\n\nTry Guix: first start\n\n"
                "Choose the password of the account '" #$%try-guix-account "'.\n"
                "The desktop starts without it; sudo asks for it.\n\n")
           (let loop ()
             (let ((password (ask "New password: ")))
               (cond ((string-null? password)
                      (say "The password must not be empty.\n\n")
                      (loop))
                     ;; chpasswd reads NAME:PASSWORD lines.
                     ((string-index password #\:)
                      (say "The password must not contain ':'.\n\n")
                      (loop))
                     ((not (string=? password (ask "Repeat it: ")))
                      (say "The passwords differ.\n\n")
                      (loop))
                     ((not (set-password! password))
                      (say "Could not set the password.\n\n")
                      (loop)))))
           (say "\nPassword set. Starting the desktop.\n")
           (close-port port))))))

(define (first-boot-shepherd-service _)
  (list (shepherd-service
         (provision '(try-guix-first-boot))
         (requirement '(file-systems))
         (one-shot? #t)
         (documentation "Ask for the account password on the first start.")
         (start #~(lambda _
                    (zero? (system* #$first-boot-program)))))))

(define try-guix-first-boot-service-type
  (service-type
   (name 'try-guix-first-boot)
   (extensions (list (service-extension shepherd-root-service-type
                                        first-boot-shepherd-service)))
   (default-value #f)
   (description "Ask for the desktop account's password on the first start.")))

;; For etc-profile-d-service-type: the auto-login console runs the compositor;
;; other consoles, the serial console and SSH get an ordinary shell.
(define try-guix-session-script
  (plain-file "try-guix-session.sh"
              (string-append "\
if [ \"$(tty)\" = /dev/tty1 ] && [ -z \"$WAYLAND_DISPLAY\" ] \\
   && [ \"$(id -un)\" = " %try-guix-account " ]; then
  exec start-hyprland
fi
")))
