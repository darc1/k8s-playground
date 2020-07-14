provider "aws" {
  profile = var.profile
  region  = var.region
}

variable "env_id" {
  type        = string
  description = "identifier for the cluster"
  default     = "chen"
}

variable "profile" {
  type        = string
  description = "credentials profile to use"
  default     = null
}

variable "region" {
  type        = string
  description = "region to depoly into"
  default     = "eu-west-1"
}

variable "vpc_cidr_block" {
  type        = string
  description = "cidr block for the vpc"
  default     = "172.16.0.0/16"
}

variable "node_count" {
  type        = number
  description = "number of nodes excluding the controller, for e.g node_count=3 then 1 controller and 3 nodes, 4 vms in total."
  default     = 2
}

variable "ami" {
  type        = string
  description = "ami for node vm"
  default     = "ami-089cc16f7f08c4457"
}

variable "node_instance_type" {
  type        = string
  description = "instance type for node"
  default     = "t3.medium"
}

variable "key_pair" {
  type        = string
  description = "key pair for instance ssh access"
  //  validation {
  //    condition     = var.key_pair != null
  //    error_message = "Enter key-pair name."
  //  }
}

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_iam_role" "caller" {
  name = split("/", data.aws_caller_identity.current.arn)[1]
}


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
  key_name  = var.key_pair
  user_data = <<EOF
#!/bin/bash

sudo mkdir -p /opt/k8s-playground
chown ubuntu:ubuntu -R /opt/k8s-playground
exec > >(tee "/opt/k8s-playground/startup.log") 2>&1

swapof -a
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository -y \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add
sudo apt-add-repository -y "deb http://apt.kubernetes.io/ kubernetes-xenial main"
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io kubeadm kubelet kubectl awscli
sudo apt-mark hold docker-ce docker-ce-cli containerd.io kubeadm kubelet kubectl
sudo systemctl enable kubelet.service
sudo systemctl enable docker.service
sudo hostnamectl set-hostname "k8s-playground-${var.env_id}-controller"
echo 127.0.0.1 "k8s-playground-${var.env_id}-controller" >> /etc/hosts

sudo kubeadm init --pod-network-cidr=192.168.0.0/16

mkdir -p /home/ubuntu/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config

pushd /opt/k8s-playground
wget https://docs.projectcalico.org/manifests/calico.yaml
sudo -u ubuntu kubectl apply -f calico.yaml
popd

TOKEN=$(kubeadm token list | awk 'FNR > 1 { print $1 }')
CERT=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')

echo "#!/bin/bash" > /home/ubuntu/kubeadm_join.sh
echo "sudo kubeadm join ${aws_network_interface.controller_iface.private_ip}:6443 --token $TOKEN --discovery-token-ca-cert-hash sha256:$CERT" >> /home/ubuntu/kubeadm_join.sh
sudo chown ubuntu:ubuntu /home/ubuntu/kubeadm_join.sh
aws s3 cp /home/ubuntu/kubeadm_join.sh s3://${aws_s3_bucket.config_bucket.id}/${var.env_id}/kubeadm_join.sh

sudo reboot
EOF

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
  key_name  = var.key_pair
  user_data = <<EOF
#!/bin/bash
sudo mkdir -p /opt/k8s-playground
chown ubuntu:ubuntu -R /opt/k8s-playground
exec > >(tee "/opt/k8s-playground/startup.log") 2>&1

swapof -a
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository -y \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"

sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io



curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add
sudo apt-add-repository -y "deb http://apt.kubernetes.io/ kubernetes-xenial main"
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io kubeadm kubelet kubectl awscli
sudo apt-mark hold docker-ce docker-ce-cli containerd.io kubeadm kubelet kubectl
sudo systemctl enable kubelet.service
sudo systemctl enable docker.service
sudo hostnamectl set-hostname "k8s-playground-${var.env_id}-node-${count.index}"
echo 127.0.0.1 "k8s-playground-${var.env_id}-node-${count.index}" >> /etc/hosts
sudo -u ubuntu aws s3 cp s3://${aws_s3_bucket.config_bucket.id}/${var.env_id}/kubeadm_join.sh /opt/k8s-playground/

sudo chmod +x /opt/k8s-playground/kubeadm_join.sh
sudo chown ubuntu:ubuntu /opt/k8s-playground/kubeadm_join.sh
sudo -u ubuntu /opt/k8s-playground/kubeadm_join.sh

sudo reboot
EOF

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
