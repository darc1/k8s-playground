
resource "aws_s3_bucket" "config_bucket" {
  bucket        = "k8s-playground-${var.env_id}-${var.region}"
  acl           = "private"
  force_destroy = true
  tags = {
    Name        = "k8s-playground-${var.env_id}-${var.region}"
    Environment = "Dev"
  }
}

resource "aws_iam_role" "node_role" {
  name                 = "k8s-playground-${var.env_id}"
  permissions_boundary = data.aws_iam_role.caller.permissions_boundary
  assume_role_policy   = <<EOF
{
	"Version": "2012-10-17",
	"Statement": [
			{
				"Action": "sts:AssumeRole",
				"Principal": {
				"Service": "ec2.amazonaws.com"
			},
				"Effect": "Allow"
			}
	]
}
EOF
}

resource "aws_iam_policy" "node_policy" {
  name        = "k8s-playground-policy-${var.env_id}"
  description = "k8s playground policy for ${var.env_id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetBucketLocation",
                "s3:GetObject",
                "s3:ListBucket",
                "s3:PutObject",
                "s3:GetBucketAcl"
            ],
            "Resource": [
                "${aws_s3_bucket.config_bucket.arn}",
                "${aws_s3_bucket.config_bucket.arn}/*"
            ]
        }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.node_role.name
  policy_arn = aws_iam_policy.node_policy.arn
}

resource "aws_iam_instance_profile" "node_profile" {
  name = aws_iam_role.node_role.name
  role = aws_iam_role.node_role.name
}

resource "aws_vpc" "playground_vpc" {
  cidr_block = var.vpc_cidr_block
  tags       = { Name = var.env_id }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.playground_vpc.id
}

resource "aws_default_route_table" "r" {
  default_route_table_id = aws_vpc.playground_vpc.default_route_table_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "default table ${var.env_id}"
  }
}

resource "aws_subnet" "k8s_playground_sn" {
  count                   = length(data.aws_availability_zones.available.names)
  vpc_id                  = aws_vpc.playground_vpc.id
  cidr_block              = replace(aws_vpc.playground_vpc.cidr_block, "0.0/16", "${0 + (16 * count.index)}.0/20")
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "k8s_playground_${var.env_id}_${data.aws_availability_zones.available.names[count.index]}"
  }
}

resource "aws_security_group" "k8s_playground_sg" {
  name        = "k8s_playgroud_${var.env_id}"
  description = "Security Group for k8s"
  vpc_id      = aws_vpc.playground_vpc.id

  ingress {
    description = "k8s api"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    description = "k8s node ports"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    description = "ssh"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "k8s_playgroud_${var.env_id}_sg"
  }
}

resource "aws_network_interface" "controller_iface" {
  subnet_id         = aws_subnet.k8s_playground_sn[0].id
  security_groups   = [aws_security_group.k8s_playground_sg.id]
  source_dest_check = false
  private_ips       = [replace(aws_vpc.playground_vpc.cidr_block, "0/16", "10")]
}

resource "aws_network_interface" "nodes_ifce" {
  count             = var.node_count
  subnet_id         = aws_subnet.k8s_playground_sn[0].id
  security_groups   = [aws_security_group.k8s_playground_sg.id]
  source_dest_check = false
  private_ips       = [replace(aws_vpc.playground_vpc.cidr_block, "0/16", "${11 + count.index}")]
}

resource "aws_instance" "k8s_controller" {
  instance_type        = var.node_instance_type
  availability_zone    = data.aws_availability_zones.available.names[0]
  ami                  = var.ami
  iam_instance_profile = aws_iam_instance_profile.node_profile.name
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.controller_iface.id
  }
  root_block_device {
    volume_type = "gp2"
    volume_size = 100
  }
  key_name = var.key_pair
  user_data = templatefile("${path.module}/controller-init.tmpl", {
    env_id                = var.env_id,
    controller_private_ip = aws_network_interface.controller_iface.private_ip
    s3_bucket             = aws_s3_bucket.config_bucket.id
  })

  tags = {
    Name = "k8s-playground-${var.env_id}-controller"
  }
}

resource "time_sleep" "k8s_controller_wait" {
  depends_on      = [aws_instance.k8s_controller]
  create_duration = "180s"
}

resource "aws_instance" "k8s_nodes" {
  depends_on           = [time_sleep.k8s_controller_wait]
  count                = var.node_count
  instance_type        = var.node_instance_type
  availability_zone    = data.aws_availability_zones.available.names[0]
  ami                  = var.ami
  iam_instance_profile = aws_iam_instance_profile.node_profile.name
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.nodes_ifce[count.index].id
  }
  root_block_device {
    volume_type = "gp2"
    volume_size = 100
  }
  key_name = var.key_pair
  user_data = templatefile("${path.module}/node-init.tmpl", {
    env_id    = var.env_id,
    index     = count.index
    s3_bucket = aws_s3_bucket.config_bucket.id
  })
  tags = {
    Name = "k8s-playground-${"${var.env_id}-node-${count.index}"}"
  }
}

output "controller_public_ip" {
  value = aws_instance.k8s_controller.public_ip
}

output "nodes_public_ip" {
  value = {
    for node in aws_instance.k8s_nodes :
    node.tags.Name => node.public_ip
  }
}
