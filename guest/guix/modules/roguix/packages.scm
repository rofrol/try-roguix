;;; Roguix — compositor packages newer than the pinned Guix checkout.
;;;
;;; The pinned checkout ships Hyprland 0.55.4 with Aquamarine 0.12.1, which
;;; cannot switch to a larger mode on virtio-gpu (see guest/guix/README.md).
;;; These definitions reproduce the known-good Arch guest pair: Hyprland 0.56.1
;;; with the rounded-border patch and Aquamarine 0.14.0, whose reviewed source
;;; SHA-256 values are noted below (test_build.py pins them).
;;;
;;; This file is project code, not part of the authenticated Guix channel: it is
;;; reviewed and committed like any other source. The build passes this
;;; directory with -L; the image also installs it for in-guest reconfigure.
(define-module (roguix packages)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system copy)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages python)
  #:use-module (gnu packages readline)
  #:use-module (gnu packages cpp)
  #:use-module (gnu packages freedesktop)
  #:use-module ((gnu packages commencement) #:select (gcc-toolchain-15))
  #:use-module (gnu packages window-management)
  #:use-module ((gnu packages xdisorg) #:prefix xdisorg:)
  #:export (hyprutils-0.14
            wayland-protocols-1.49
            aquamarine-0.14
            hyprland-0.56
            roguix-display-sync
            quickshell-0.3))

;; Hyprland 0.56 requires hyprutils >= 0.14.0; the Arch guest uses 0.14.2.
(define hyprutils-0.14
  (package
    (inherit hyprutils)
    (version "0.14.2")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://github.com/hyprwm/hyprutils/archive/v"
                                  version "/hyprutils-" version ".tar.gz"))
              (sha256
               (base32
                "0nqph0wmbi7i8mc02cw6qdg0wn68yql3nm89lq1gn141ijqbfq90"))))))

;; wayland-protocols 1.49 needs wayland-scanner >= 1.25 at build time. This
;; newer wayland is used only for that build step, not linked into the system.
(define wayland-scanner-1.26
  (package
    (inherit wayland)
    (version "1.26.0")
    (source (origin
              (inherit (package-source wayland))
              (uri (string-append "https://gitlab.freedesktop.org/wayland"
                                  "/wayland/-/releases/" version "/downloads/"
                                  "wayland-" version ".tar.xz"))
              (sha256
               (base32
                "18xpc8qv5ll1hfswjfphzlbzrbrihgpyby46w81rk5p48sm6w5v4"))))
    ;; 1.26 builds its manual with mdbook; a build tool needs no manual.
    (outputs '("out"))
    (arguments (list #:configure-flags #~'("-Ddocumentation=false")))))

;; Hyprland 0.56 requires wayland-protocols >= 1.49. It is header/XML data, so
;; it is replaced only as a direct input, not throughout the closure.
(define wayland-protocols-1.49
  (package
    (inherit wayland-protocols)
    (inputs (list wayland-scanner-1.26))
    (version "1.49")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://gitlab.freedesktop.org/wayland/"
                                  "wayland-protocols/-/releases/" version
                                  "/downloads/wayland-protocols-" version
                                  ".tar.xz"))
              (sha256
               (base32
                "050b4jny5pkylx79fpcki9hzzy8f9xvf8k4brrxgyv9djis8yk7c"))))))

;; The Arch guest builds Hyprland 0.56.1 with glaze 7.2.0. Header-only, used
;; by Hyprland alone.
;; SHA-256 17dba19ae63ae48f94994f00d49d5cb3c8f1306db1046c534c4828662490b7d4.
(define glaze-7.2
  (package
    (inherit glaze)
    (version "7.2.0")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://github.com/stephenberry/glaze/archive"
                                  "/refs/tags/v" version ".tar.gz"))
              (file-name (string-append "glaze-" version ".tar.gz"))
              (sha256
               (base32
                "1m5pj0j6ca289i9nq15idlqg3j5kbjfx802gk6a8zr1swsda3nqp"))))))

;; SHA-256 5dcf0b17f7dd51539fd7e79d68484f04240b3b63cf9f5f21d5b6dea0088168f9.
(define aquamarine-0.14
  (package
    (inherit xdisorg:aquamarine)
    (version "0.14.0")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://github.com/hyprwm/aquamarine/archive/v"
                                  version "/aquamarine-" version ".tar.gz"))
              (sha256
               (base32
                "1yb8h44a1pmnslhmz7ygccxhn9049x46i7g7sygm6lfxywbhpksx"))))
    ;; One hyprutils per process: build against the same version as Hyprland.
    (inputs (modify-inputs (package-inputs xdisorg:aquamarine)
              (replace "hyprutils" hyprutils-0.14)
              (replace "wayland-protocols" wayland-protocols-1.49)))))

;; Rebuild every hypr* library in Hyprland's closure against the same
;; hyprutils and Aquamarine, so no process links two ABI versions.
(define rewrite-hypr-libraries
  (package-input-rewriting
   `((,hyprutils . ,hyprutils-0.14)
     (,xdisorg:aquamarine . ,aquamarine-0.14))))

;; SHA-256 c5b26eb377360358d01839a1de43fdc004a33e56d6a5d442fdad69b9f3a10549.
;; 0.56 needs a newer C++26 toolchain than the default GCC 14. The Arch guest
;; uses GCC 16, but this checkout's aarch64 gcc-16.2.0 ships a libstdc++
;; configured without C99 math (_GLIBCXX11_USE_C99_MATH undefined), so
;; std::signbit and friends do not exist. GCC 15 is sound; its only gap is
;; the single C++23 std::ranges::starts_with call, rewritten below.
(define hyprland-0.56
  (package-with-c-toolchain
   (rewrite-hypr-libraries
    (package
     (inherit hyprland)
     (version "0.56.1")
     (source (origin
               (inherit (package-source hyprland))
               (uri (string-append "https://github.com/hyprwm/Hyprland"
                                   "/releases/download/v" version
                                   "/source-v" version ".tar.gz"))
               (sha256
                (base32
                 "0j85l7rvjsddzm1d99fnaqza6160zm1xx89r3385h0rnfyrnxcn5"))
               ;; Byte-identical to guest/patches/hyprland (test_build.py).
               (patches
                (list (local-file
                       "hyprland-rounded-border-coverage.patch")))
               ;; truthy() tests a lowercased transform_view against string_view
               ;; prefixes; comparing its first prefix.size() elements is the
               ;; C++20 equivalent (a shorter input yields a shorter range).
               (modules '((guix build utils)))
               (snippet
                '(substitute* "src/helpers/MiscFunctions.cpp"
                   (("std::ranges::starts_with\\(str_view, prefixes\\)")
                    "std::ranges::equal(str_view | std::views::take(prefixes.size()), prefixes)")))))
     ;; GCC 15 is applied as the whole C toolchain below: only a gcc-15 input
     ;; would leave the default GCC headers on the include path as well.
     (native-inputs (modify-inputs (package-native-inputs hyprland)
                      (delete "gcc")))
     (inputs (modify-inputs (package-inputs hyprland)
               (replace "wayland-protocols" wayland-protocols-1.49)
               (replace "glaze" glaze-7.2)
               ;; 0.56 adds emulated input (libeis) for remote desktop.
               ;; hyprctl 0.56 gains an interactive mode using readline.
               (append libei readline)))))
   `(("toolchain" ,gcc-toolchain-15))))

;; Aquamarine does not refresh its mode cache when QEMU changes the virtio-gpu
;; EDID. This helper (Try Omarchy's omarchy-native-display-sync) parses the
;; fresh EDID and
;; applies a complete modeline through hyprctl on every DRM hotplug change.
;; It runs as a child of the Hyprland session, started from hypr-vm.lua.
(define roguix-display-sync
  (package
    (name "roguix-display-sync")
    (version "1")
    (source (local-file "display-sync"))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan #~'(("display-sync" "bin/roguix-display-sync"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'wrap
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((program (string-append #$output
                                            "/bin/roguix-display-sync")))
                (chmod program #o555)
                (wrap-program program
                  `("PATH" ":" prefix
                    ,(map (lambda (name)
                            (dirname (search-input-file inputs name)))
                          '("bin/python3" "bin/hyprctl" "bin/udevadm"
                            "bin/sleep"))))))))))
    (inputs (list bash-minimal python-minimal hyprland-0.56 eudev coreutils))
    (home-page "https://github.com/omacom/try-omarchy")
    (synopsis "Keep Hyprland's mode in sync with the QEMU window")
    (description "Apply the virtio-gpu EDID's preferred mode to Hyprland.")
    (license license:expat)))

;; The Omarchy 4 shell is a Quickshell application; the Arch guest runs it on
;; Quickshell 0.3.1, one release after Guix's.
(define quickshell-0.3
  (package
    (inherit quickshell)
    (version "0.3.1")
    (source (origin
              (inherit (package-source quickshell))
              (uri (git-reference
                    (url "https://git.outfoxxed.me/quickshell/quickshell")
                    (commit (string-append "v" version))))
              (file-name (git-file-name "quickshell" version))
              (sha256
               (base32
                "1mhpgy7zcyqmqj6h1b0fhbriimkp2563lkgcdj5ipr32krkgdd88"))))))
