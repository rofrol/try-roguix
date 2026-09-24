;;; Try Guix — the Omarchy 4 desktop on Guix System.
;;;
;;; Omarchy 4 ("Quattro") is installed like the Arch guest installs it: the
;;; pinned upstream tree as a package at /usr/share/omarchy (OMARCHY_PATH's
;;; default), its commands on PATH, and its user configuration seeded into
;;; the desktop account's home. The desktop is its own Hyprland Lua
;;; configuration and its Quickshell shell (bar, background, launcher menu,
;;; notifications, lock), themed Tokyo Night.
;;;
;;; What Omarchy expects from Arch is replaced, not emulated: uwsm-app,
;;; systemd-cat and `systemctl --user' become no-frills compatibility
;;; commands, busctl's notification calls go through gdbus, and nothing from
;;; its installer, package manager or systemd units runs. Menus that manage
;;; Arch packages or systemd timers therefore do nothing here.
(define-module (try-guix omarchy)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system font)
  #:use-module (guix build-system trivial)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages fontutils)
  #:use-module (gnu packages fonts)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages gnome)
  #:use-module (gnu packages gnome-xyz)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages python)
  #:use-module (gnu packages qt)
  #:use-module (gnu packages terminals)
  #:use-module (gnu packages web)
  #:use-module (gnu packages xdisorg)
  #:use-module (gnu services)
  #:use-module (gnu system pam)
  #:use-module (try-guix packages)
  #:export (omarchy
            font-jetbrains-mono-nerd
            try-guix-omarchy-compat
            try-guix-omarchy-service-type))

;; guest/spec.json upstream: basecamp/omarchy 4.0.2, tree 24ff1b25.
(define omarchy
  (package
    (name "omarchy")
    (version "4.0.2")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/basecamp/omarchy")
                    (commit "346e69e1cec6c4e8924531874af6ba010a1bc99e")))
              (file-name (git-file-name name version))
              (sha256
               (base32
                "1ipk7ip7h5dhglbax7w7rqmwcw9lcvsdm9bvavcaxg1jg0iq7mhf"))))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~'(("." "share/omarchy" #:exclude-regexp ("^\\.git"))
          ("default/fonts/omarchy/omarchy.ttf" "share/fonts/omarchy/"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'link-commands
            ;; The Arch package installs each command in /usr/bin.
            (lambda _
              (let ((bin (string-append #$output "/bin")))
                (mkdir-p bin)
                (for-each (lambda (command)
                            (symlink command
                                     (string-append bin "/" (basename command))))
                          (find-files (string-append #$output
                                                     "/share/omarchy/bin")))))))))
    (inputs (list bash))
    (home-page "https://omarchy.org")
    (synopsis "Omarchy desktop configuration, shell and commands")
    (description "Omarchy is an opinionated Hyprland desktop: its Hyprland
configuration, Quickshell desktop shell, themes and helper commands.")
    (license license:expat)))

;; The Arch guest ships ttf-jetbrains-mono-nerd 3.5.1; Omarchy's fontconfig
;; maps monospace to it and the shell's bar icons are its Nerd Font glyphs.
(define font-jetbrains-mono-nerd
  (package
    (name "font-jetbrains-mono-nerd")
    (version "3.5.1")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://github.com/ryanoasis/nerd-fonts"
                                  "/releases/download/v" version
                                  "/JetBrainsMono.tar.xz"))
              (sha256
               (base32
                "1kqhj2hcs3bpg8rhsb67ncg6hkl3jklngy0n7v8rsgv90gwyim84"))))
    (build-system font-build-system)
    (home-page "https://www.nerdfonts.com")
    (synopsis "JetBrains Mono patched with Nerd Font glyphs")
    (description "JetBrains Mono with the Nerd Fonts icon glyphs.")
    (license license:silofl1.1)))

;;; Compatibility commands for Omarchy's Arch assumptions, plus the Arch
;;; guest's xdg-terminal-exec (byte-identical copy) and the per-user seed.

(define try-guix-omarchy-compat
  (package
    (name "try-guix-omarchy-compat")
    (version "1")
    (source (local-file "." "try-guix-omarchy-compat-source"
                        #:recursive? #t
                        #:select? (lambda (file stat)
                                    (or (eq? 'directory (stat:type stat))
                                        (member (basename file)
                                                '("busctl" "xdg-terminal-exec"
                                                  "omarchy-seed"))))))
    (build-system copy-build-system)
    (arguments
     (list
      #:install-plan
      #~'(("busctl" "bin/")
          ("xdg-terminal-exec" "bin/")
          ("omarchy-seed" "bin/try-guix-omarchy-seed"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'install-shims
            (lambda* (#:key inputs #:allow-other-keys)
              (define sh #$(file-append bash-minimal "/bin/sh"))
              (define (shim name text)
                (let ((file (string-append #$output "/bin/" name)))
                  (call-with-output-file file
                    (lambda (port) (format port "#!~a~%~a" sh text)))
                  (chmod file #o555)))
              ;; uwsm-app [OPTIONS] -- COMMAND...: run COMMAND directly.
              (shim "uwsm-app" "\
while [ $# -gt 0 ] && [ \"$1\" != -- ]; do shift; done
[ $# -gt 0 ] && shift
exec \"$@\"
")
              ;; systemd-cat [-t TAG] [--] COMMAND...: log to the session's
              ;; stderr instead of the journal.
              (shim "systemd-cat" "\
while [ $# -gt 0 ]; do
  case \"$1\" in
    --) shift; break ;;
    -t|-p) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec \"$@\"
")
              ;; No user service manager: accept `systemctl --user ...'
              ;; calls (environment import, timer queries) as empty successes.
              (shim "systemctl" "exit 0\n")
              (for-each (lambda (program)
                          (chmod (string-append #$output "/bin/" program) #o555))
                        '("busctl" "xdg-terminal-exec" "try-guix-omarchy-seed"))
              (wrap-program (string-append #$output "/bin/busctl")
                `("PATH" ":" prefix
                  (,(dirname (search-input-file inputs "bin/gdbus"))))))))))
    (inputs (list bash bash-minimal `(,glib "bin") python-minimal))
    (home-page "https://github.com/omacom/try-omarchy")
    (synopsis "Run Omarchy's commands on Guix System")
    (description "Compatibility commands for Omarchy's systemd and uwsm
calls, a busctl subset over gdbus, and the Omarchy per-user seed.")
    (license license:expat)))

;; Hyprland additions for the VM: loaded from ~/.config/hypr/monitors.lua,
;; where the Arch guest appends its own QEMU fragment. Like that fragment it
;; hides Hyprland's cursor when the launcher reports VirGL (Cocoa draws the
;; Mac's cursor over the guest) and follows the window size; it also starts
;; the host bridges and the per-session sound server (see integrations.scm).
(define hypr-vm-lua
  (plain-file "hypr-vm.lua" "\
-- Try Guix VM integration, loaded from ~/.config/hypr/monitors.lua.
local function host_setting(expected)
  local file = io.open(\"/run/try-guix/host-settings\", \"r\")
  if not file then return false end
  local settings = file:read(\"*a\") or \"\"
  file:close()
  for setting in settings:gmatch(\"%S+\") do
    if setting == expected then return true end
  end
  return false
end

if host_setting(\"omarchy.qemu_virgl=1\") then
  hl.config({ cursor = { invisible = true } })
end

hl.on(\"hyprland.start\", function()
  hl.exec_cmd(\"try-guix-display-sync\")
  hl.exec_cmd(\"try-guix-agent /dev/snd/controlC0 pipewire\")
  hl.exec_cmd(\"try-guix-agent /dev/snd/controlC0 wireplumber\")
  hl.exec_cmd(\"try-guix-agent /dev/snd/controlC0 pipewire-pulse\")
  hl.exec_cmd(\"try-guix-agent /dev/virtio-ports/dev.tryomarchy.clipboard try-guix-clipboard-bridge\")
  hl.exec_cmd(\"try-guix-agent /dev/virtio-ports/dev.tryomarchy.audio try-guix-audio-bridge\")
  hl.exec_cmd(\"try-guix-agent /dev/virtio-ports/dev.tryomarchy.camera try-guix-camera-bridge\")
end)
"))

;; Quickshell's lock plugin authenticates with this PAM service and refuses
;; to lock without it; Omarchy's Arch stack is pam_unix underneath.
(define (omarchy-pam-services _)
  (list (unix-pam-service "omarchy-lock-password")))

(define try-guix-omarchy-service-type
  (service-type
   (name 'try-guix-omarchy)
   (extensions
    (list (service-extension special-files-service-type
                             (const `(("/usr/share/omarchy"
                                       ,(file-append omarchy "/share/omarchy")))))
          (service-extension etc-service-type
                             (const `(("try-guix-hypr-vm.lua" ,hypr-vm-lua))))
          (service-extension pam-root-service-type omarchy-pam-services)
          (service-extension profile-service-type
                             (const
                              (list omarchy try-guix-omarchy-compat quickshell-0.3
                                    foot jq socat inotify-tools hyprsunset
                                    fontconfig procps gawk util-linux curl
                                    `(,gtk+ "bin") libnotify xdg-user-dirs
                                    qtimageformats yaru-theme font-liberation
                                    font-jetbrains-mono-nerd)))))
   (default-value #f)
   (description "Install Omarchy 4's desktop, shell and theme.")))
