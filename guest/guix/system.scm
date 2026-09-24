;; The Roguix image: the base system with no extra packages. In the guest,
;; /etc/config.scm calls the same procedure with the owner's packages.
(use-modules (roguix system))

(roguix-operating-system)
