Rendu d'un profil de provisioning : le cloud-init agrégé et le script iPXE sont
produits sans contacter de machine ni de serveur de découverte.

  $ hamac provision-dryrun --profile=profile.yaml --bundles-dir=bundles
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
partiel. On retire le bloc `params` du profil :

  $ sed '/params:/,$d' profile.yaml > no-params.yaml
  $ tail -3 no-params.yaml
  
  bundles:
    - name: dev-workstation
  $ hamac provision-dryrun --profile=no-params.yaml --bundles-dir=bundles
  hamac: [ERROR] bundle 'dev-workstation' : paramètre requis 'username' manquant
  [1]
