Rendu d'un profil de provisioning : le cloud-init agrégé et le script iPXE sont
produits sans contacter de machine ni de serveur de découverte.

  $ hamac provision-dryrun --profile=profile.loaf --bundles-dir=bundles
  === cloud-init ===
  #cloud-config
  # Généré par hamac pour le profile 'dev-workstation-demo'
  users:
  - name: devuser
    gecos: Example Developer
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: docker, sudo
    lock_passwd: true
    ssh_authorized_keys:
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE
      example@hamac
  timezone: Europe/Paris
  package_update: true
  packages:
  - git
  - vim
  - curl
  - ca-certificates
  - sudo
  - openssh-server
  - docker.io
  - python3
  - python3-pip
  - tmux
  - htop
  - jq
  - rsync
  write_files:
  - path: /etc/motd
    permissions: "0644"
    content: '============================================================
  
      Provisioned by hamac (bundle: dev-workstation)
  
      User: Example Developer (devuser)
  
      ============================================================
  
      '
  runcmd:
  - install -d -o devuser -g devuser /home/devuser/.config /home/devuser/.local/bin
    /home/devuser/projects
  - bash -c 'printf "\n# hamac/dev-workstation\nexport PATH=\"$HOME/.local/bin:$PATH\"\nalias
    ll=\"ls -lah\"\n" >> /home/devuser/.bashrc'
  - chown devuser:devuser /home/devuser/.bashrc
  - systemctl enable --now ssh || systemctl enable --now sshd
  - systemctl enable --now docker
  - usermod -aG docker devuser || true
  - echo "hamac dev-workstation provisioning done"
  - systemctl enable --now ssh
  
  === iPXE ===
  #!ipxe
  # Généré par hamac (provisioning_gen)
  # Image: debian-12-amd64-genericcloud (qcow2)
  
  set base-url https://cdimage.debian.org/cdimage/cloud/bookworm/latest
  kernel https://cdimage.debian.org/cdimage/cloud/bookworm/latest/vmlinuz initrd=initrd.img boot=live components
  initrd https://cdimage.debian.org/cdimage/cloud/bookworm/latest/initrd.img
  boot
  
  === OS ===
  url: https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
  sha256: 0000000000000000000000000000000000000000000000000000000000000000
  format: qcow2

Un paramètre obligatoire du bundle non fourni est une erreur, pas un rendu
partiel. On retire du profil le sous-bloc des paramètres du bundle :

  $ sed '/^  bundle dev_workstation {/,/^  }/d' profile.loaf > no-params.loaf
  $ tail -4 no-params.loaf
  
    bundles [dev_workstation].
  
  }
  $ hamac provision-dryrun --profile=no-params.loaf --bundles-dir=bundles
  hamac: [ERROR] bundle 'dev-workstation' : paramètre requis 'username' manquant
  [1]

Deux fragments qui écrivent le même fichier avec des contenus différents font
échouer le rendu.

  $ hamac provision-dryrun --profile=collision.loaf --bundles-dir=bundles 2>&1 | grep write_files
  hamac: [ERROR] write_files : le bundle dev-workstation et cloud_init_extra écrivent tous deux '/etc/motd' avec des contenus différents

Un profil donne à un bundle les paramètres que celui-ci déclare, sous la
forme de leur type : items pour une liste, value pour un scalaire, true ou
false pour un booléen ; un objet ne vient que de l'enregistrement de la
machine.

  $ hamac validate params 2>&1 | grep E007
  hamac: [ERROR] params/profile.loaf:14:5: [E007] parameter s of the bundle b is not a list: give it with value
  hamac: [ERROR] params/profile.loaf:15:5: [E007] parameter l of the bundle b is a list: give it with items
  hamac: [ERROR] params/profile.loaf:16:5: [E007] parameter f of the bundle b is a boolean: true or false
  hamac: [ERROR] params/profile.loaf:17:5: [E007] parameter o of the bundle b is an object: only the record of the machine gives it
  hamac: [ERROR] params/profile.loaf:18:5: [E007] z is not a parameter of the bundle b
