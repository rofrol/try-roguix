;;; Roguix — Omarchy applications the pinned Guix does not package.
;;;
;;; These install the upstream projects' own aarch64 release binaries instead
;;; of building from source (docs/decisions/0003-upstream-binary-packages.md).
;;; Each source is pinned by its SHA-256; the builder signs the result and
;;; roguix.frolow.dev serves it like any other Roguix item.
(define-module (roguix apps)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:use-module (guix build-system copy)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages linux)
  #:export (lazygit-bin
            lazydocker-bin
            gum-bin
            dua-bin
            cliamp-bin
            fastfetch-without-zfs))

;; A statically linked upstream release: unpack the tarball into the build
;; directory and install PLAN (copy-build-system's #:install-plan).
(define* (static-binary-package name version url hash plan
                                #:key home-page synopsis description)
  (package
    (name name)
    (version version)
    (source (origin
              (method url-fetch)
              (uri url)
              (sha256 (base32 hash))))
    (build-system copy-build-system)
    (arguments
     (list
      ;; Upstream strips its release binaries.
      #:strip-binaries? #f
      #:install-plan plan
      #:phases
      #~(modify-phases %standard-phases
          ;; Some tarballs have no top-level directory.
          (replace 'unpack
            (lambda* (#:key source #:allow-other-keys)
              (invoke "tar" "xzf" source))))))
    (supported-systems '("aarch64-linux"))
    (home-page home-page)
    (synopsis synopsis)
    (description description)
    (license license:expat)))

(define lazygit-bin
  (static-binary-package
   "lazygit" "0.65.1"
   "https://github.com/jesseduffield/lazygit/releases/download/v0.65.1/lazygit_0.65.1_linux_arm64.tar.gz"
   "19q0830gd1vd3jfq1v8j6r9flrx2mnzvkxqvn7yjskyzdbgyras9"
   #~'(("lazygit" "bin/"))
   #:home-page "https://github.com/jesseduffield/lazygit"
   #:synopsis "Terminal UI for Git"
   #:description "Lazygit is a terminal user interface for Git commands."))

(define lazydocker-bin
  (static-binary-package
   "lazydocker" "0.25.2"
   "https://github.com/jesseduffield/lazydocker/releases/download/v0.25.2/lazydocker_0.25.2_Linux_arm64.tar.gz"
   "08yy63sydvj934p6m37dxr0460mmmlykmn26svkmg9dahnv3hp00"
   #~'(("lazydocker" "bin/"))
   #:home-page "https://github.com/jesseduffield/lazydocker"
   #:synopsis "Terminal UI for Docker"
   #:description "Lazydocker is a terminal user interface for Docker and
Docker Compose."))

(define gum-bin
  (static-binary-package
   "gum" "2.0.2"
   "https://github.com/charmbracelet/gum/releases/download/v2.0.2/gum_2.0.2_Linux_arm64.tar.gz"
   "1md1rw60xf2pyc65ydqi9mm1i609nzwrzdaqpgr8330yxia8pgwf"
   #~'(("gum_2.0.2_Linux_arm64/gum" "bin/")
       ("gum_2.0.2_Linux_arm64/manpages/gum.1.gz" "share/man/man1/"))
   #:home-page "https://github.com/charmbracelet/gum"
   #:synopsis "Interactive prompts for shell scripts"
   #:description "Gum provides inputs, choosers, spinners and styled text for
shell scripts; Omarchy's menus and installers use it."))

(define dua-bin
  (static-binary-package
   "dua" "2.45.0"
   "https://github.com/Byron/dua-cli/releases/download/v2.45.0/dua-v2.45.0-aarch64-unknown-linux-musl.tar.gz"
   "0nkqmnv79hs3b9bm8ixyhq1y2gzb8pid7hnarhpdmijjdds0xj9s"
   #~'(("dua-v2.45.0-aarch64-unknown-linux-musl/dua" "bin/"))
   #:home-page "https://github.com/Byron/dua-cli"
   #:synopsis "Disk usage analyzer"
   #:description "Dua shows and interactively deletes what uses disk space;
Omarchy's Disk Usage entry runs it."))

;; cliamp's release binary links glibc and ALSA dynamically. patchelf breaks
;; this Go binary (the loader segfaults), so bin/cliamp runs the untouched
;; binary through the store's loader with an explicit library path.
(define cliamp-bin
  (package
    (name "cliamp")
    (version "2.2.0")
    (source (origin
              (method url-fetch)
              (uri "https://github.com/bjarneo/cliamp/releases/download/v2.2.0/cliamp-linux-arm64")
              (sha256
               (base32 "1d582541z4gar74h34dhghc70nwj881157277hln5dz4mpskkbll"))))
    (build-system copy-build-system)
    (arguments
     (list
      #:strip-binaries? #f
      ;; Guile's ELF parser rejects this Go binary, and it has no RUNPATH.
      #:validate-runpath? #f
      #:install-plan #~'(("cliamp" "libexec/"))
      #:phases
      #~(modify-phases %standard-phases
          (replace 'unpack
            (lambda* (#:key source #:allow-other-keys)
              (copy-file source "cliamp")
              (chmod "cliamp" #o555)))
          (add-after 'install 'wrap
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((loader (search-input-file
                             inputs "lib/ld-linux-aarch64.so.1"))
                    (libraries
                     (string-append
                      (dirname (search-input-file inputs "lib/libasound.so.2"))
                      ":"
                      (dirname (search-input-file inputs "lib/libc.so.6"))))
                    (wrapper (string-append #$output "/bin/cliamp")))
                (mkdir-p (dirname wrapper))
                (call-with-output-file wrapper
                  (lambda (port)
                    (format port "#!~a~%exec ~a --library-path ~a ~a \"$@\"~%"
                            (search-input-file inputs "bin/sh")
                            loader libraries
                            (string-append #$output "/libexec/cliamp"))))
                (chmod wrapper #o555)
                (invoke wrapper "--help")))))))
    (inputs (list alsa-lib bash-minimal glibc))
    (supported-systems '("aarch64-linux"))
    (home-page "https://github.com/bjarneo/cliamp")
    (synopsis "Terminal music player")
    (description "Cliamp is a terminal music player inspired by Winamp;
Omarchy binds it to Super+Shift+Alt+M.")
    (license license:expat)))

;; Guix's fastfetch links ZFS for pool details, which a Roguix VM has none of.
;; ZFS brings a kernel module build and, through Guix's grafts, a slow first
;; roguix-update.
(define fastfetch-without-zfs
  (package
    (inherit fastfetch)
    (arguments
     (substitute-keyword-arguments (package-arguments fastfetch)
       ;; Guix links fastfetch's optional libraries directly.
       ((#:configure-flags flags #~'())
        #~(cons "-DENABLE_LIBZFS=OFF" #$flags))))
    (inputs (modify-inputs (package-inputs fastfetch)
              (delete "zfs")))))
