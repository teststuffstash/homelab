output "matchbox_ip" {
  description = "Matchbox container IP (no CIDR)."
  value       = split("/", var.matchbox_ip_cidr)[0]
}

output "matchbox_vmid" {
  value = proxmox_virtual_environment_container.matchbox.vm_id
}

output "next_step" {
  description = "Install Matchbox into the freshly-created container."
  value       = "ansible-playbook -i '${split("/", var.matchbox_ip_cidr)[0]},' ../../ansible/matchbox.yml"
}

output "backup_garage_ip" {
  description = "Longhorn backup-target Garage container IP (no CIDR)."
  value       = split("/", var.backup_garage_ip_cidr)[0]
}
