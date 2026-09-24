;;; Try Guix — services for the launcher's persistent UEFI/GPT disk.
;;;
;;; The host grows a VM disk only by extending the file. At boot this service
;;; moves the backup GPT to the new end of the disk, extends the root
;;; partition over the free space and grows its ext4 file system online. It
;;; keeps the partition's start, type, GUID and name.
(define-module (try-guix services)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:export (try-guix-grow-root-service-type))

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
