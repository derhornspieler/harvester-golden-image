# Ubuntu 24.04 LTS (Noble) — CIS L1 Server
distro = "ubuntu2404"

harvester_kubeconfig_path   = "./kubeconfig-harvester.yaml"
vm_namespace                = "rke2-prod"
harvester_network_name      = "vm-network"
harvester_network_namespace = "default"

cis_level = "l1"
cis_type  = "server"

# Uses upstream cloud image by default (comment in to use proxy-cache)
# cloud_image_url = "https://dl.aegisgroup.ch/ubuntu/noble/ubuntu-24.04-server-cloudimg-amd64.img"
# repo_mirror_url = "https://apt.aegisgroup.ch"

ssh_authorized_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAw/Ob7ikMCwPwos/Av7govYPic1jqutEM3+F7jm89uI hvst-mgmt",
]
