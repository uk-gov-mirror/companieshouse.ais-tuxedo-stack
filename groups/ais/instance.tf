
resource "aws_placement_group" "ais" {
  name     = local.common_resource_name
  strategy = "spread"
}

resource "aws_key_pair" "master" {
  key_name   = "${local.common_resource_name}-master"
  public_key = var.ssh_master_public_key
}

resource "aws_security_group" "common" {
  name   = "common-${local.common_resource_name}"
  vpc_id = data.aws_vpc.heritage.id

  tags = merge(local.common_tags, {
    Name = "common-${local.common_resource_name}"
  })
}

resource "aws_vpc_security_group_ingress_rule" "admin_ingress" {
  security_group_id = aws_security_group.common.id
  description       = "Allow SSH connectivity for application deployments"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.shared_services_management.id
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ingress_dsr_scanning_ssh" {
  security_group_id = aws_security_group.common.id
  description       = "Allow inbound SSH connectivity for DSR scanning systems"
  cidr_ipv4         = "172.19.12.0/22"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ingress_chiris_to_informix" {
  for_each = toset(local.chiris_desktop_service_cidrs)

  security_group_id = aws_security_group.common.id
  description       = "Allow inbound connectivity from CHIRIS desktop service to AIS Informix databases"
  cidr_ipv4         = each.value
  from_port         = 6278
  to_port           = 6278
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ingress_chiris_to_informix" {
  for_each = toset(local.chiris_desktop_service_cidrs)

  security_group_id = aws_security_group.common.id
  description       = "Allow inbound connectivity from CHIRIS desktop service to SFTP/SSH"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ingress_ois_to_ais_services" {
  for_each = {
    for rule in local.ais_security_group_rules : "${rule.service}-${rule.port}-${rule.cidr_ipv4}" => rule
  }

  security_group_id = aws_security_group.common.id
  description       = "Allow inbound connectivity from OIS Tuxedo services to ${upper(each.value.service)} Tuxedo services"
  cidr_ipv4         = each.value.cidr_ipv4
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "informix_ingress" {
  for_each = {
    for rule in local.informix_hdr_security_group_rules : "${rule.service}-${rule.port}-${rule.cidr_ipv4}" => rule
  }

  security_group_id = aws_security_group.common.id
  description       = "Allow Informix HDR connectivity for Tuxedo ${upper(each.value.service)} services"
  cidr_ipv4         = each.value.cidr_ipv4
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all_egress" {
  security_group_id = aws_security_group.common.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "ais" {
  count = var.instance_count

  ami             = data.aws_ami.ais_tuxedo.id
  instance_type   = var.instance_type
  key_name        = aws_key_pair.master.id
  placement_group = aws_placement_group.ais.id
  subnet_id       = element(local.application_subnet_ids_by_az, count.index) # use 'element' function for wrap-around behaviour

  iam_instance_profile   = module.instance_profile.aws_iam_instance_profile.name
  user_data_base64       = data.cloudinit_config.config[count.index].rendered
  vpc_security_group_ids = [aws_security_group.common.id]

  root_block_device {
    throughput  = var.root_volume_throughput
    volume_size = var.root_volume_size != 0 ? var.root_volume_size : local.ami_root_block_device.ebs.volume_size
    volume_type = var.root_volume_type
  }

  dynamic "ebs_block_device" {
    for_each = local.ami_lvm_block_devices
    iterator = block_device
    content {
      device_name = block_device.value.device_name
      encrypted   = block_device.value.ebs.encrypted
      iops        = var.lvm_block_devices[index(var.lvm_block_devices[*].lvm_physical_volume_device_node, block_device.value.device_name)].aws_volume_iops
      snapshot_id = block_device.value.ebs.snapshot_id
      throughput  = var.lvm_block_devices[index(var.lvm_block_devices[*].lvm_physical_volume_device_node, block_device.value.device_name)].aws_volume_throughput
      volume_size = var.lvm_block_devices[index(var.lvm_block_devices[*].lvm_physical_volume_device_node, block_device.value.device_name)].aws_volume_size_gb
      volume_type = var.lvm_block_devices[index(var.lvm_block_devices[*].lvm_physical_volume_device_node, block_device.value.device_name)].aws_volume_type
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.service_subtype}-${var.service}-${var.environment}-${count.index + 1}"
  })
  volume_tags = local.common_tags
}
