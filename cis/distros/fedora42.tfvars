# Fedora 42 — CIS L1 Server (DRAFT profiles — not for production compliance)
distro = "fedora42"

harvester_kubeconfig_path   = "./kubeconfig-harvester.yaml"
vm_namespace                = "rke2-prod"
harvester_network_name      = "vm-network"
harvester_network_namespace = "default"

cis_level = "l1"
cis_type  = "server"

# Uses upstream cloud image by default
# cloud_image_url = "https://dl.aegisgroup.ch/fedora/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
# repo_mirror_url = "https://yum.aegisgroup.ch"

ssh_authorized_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAw/Ob7ikMCwPwos/Av7govYPic1jqutEM3+F7jm89uI hvst-mgmt",
]
