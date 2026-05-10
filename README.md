CloudNotes - Project Notepad

Course: CSCI5409 - Advanced Topics in Cloud Computing
Term: Winter 2026


PROJECT OVERVIEW

Application Name : CloudNotes
Type             : 3-Tier Web Application
Region           : us-east-1 (N. Virginia)
IaC Tool         : Terraform


AWS SERVICES

Compute   : Amazon EC2 (t2.micro, Amazon Linux 2)
Database  : Amazon RDS MySQL 8.0 (db.t3.micro, 20 GB)
Network   : Amazon VPC (10.0.0.0/16)
Subnets   : public1 (10.0.1.0/24), public2 (10.0.2.0/24)
Gateway   : Internet Gateway
Security  : ec2_sg (port 80, 22), rds_sg (port 3306)


DEPLOYMENT COMMANDS

Initialize   : terraform init
Preview      : terraform plan
Deploy       : terraform apply -auto-approve
Destroy      : terraform destroy -auto-approve


EC2 ACCESS

SSH          : ssh -i your-key.pem ec2-user@<EC2_PUBLIC_IP>
App URL      : http://<EC2_PUBLIC_IP>/


DATABASE INFO

Engine       : MySQL 8.0
DB Name      : cloudnotes
Username     : admin
Password     : password123  <-- CHANGE BEFORE PRODUCTION
Port         : 3306
Host         : <RDS_ENDPOINT>  (from AWS Console after apply)


RESOURCES CREATED (12 total)

1.  aws_vpc.main
2.  aws_internet_gateway.gw
3.  aws_subnet.public1
4.  aws_subnet.public2
5.  aws_route_table.public
6.  aws_route_table_association.a1
7.  aws_route_table_association.a2
8.  aws_security_group.ec2_sg
9.  aws_security_group.rds_sg
10. aws_instance.app
11. aws_db_subnet_group.db_subnet
12. aws_db_instance.mysql


SECURITY ISSUES TO FIX

1. SSH open to 0.0.0.0/0           -> Restrict to your IP only
2. DB password hardcoded in main.tf -> Move to AWS Secrets Manager
3. No HTTPS                         -> Add ALB + ACM certificate
4. RDS in public subnet             -> Move to private subnet + NAT


COST ESTIMATE (monthly)

EC2 t2.micro (730 hrs)   : $8.47
EC2 EBS 8 GB             : $0.80
RDS db.t3.micro (730 hrs): $12.41
RDS Storage 20 GB        : $2.30
Data Transfer ~5 GB      : $0.45
CloudWatch Logs          : $0.10
Total                    : ~$24.53 / month
Free Tier estimate       : ~$2.85 / month
