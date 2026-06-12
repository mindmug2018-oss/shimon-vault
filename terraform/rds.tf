# terraform/rds.tf — RDS PostgreSQL (Write Primary)
#
# db.t3.micro is free tier in Seoul (ap-northeast-2).
# Logical replication enabled so proj-ubuntu01 can subscribe as a read replica.

resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-db-subnet-group"
  description = "Subnet group for ShimonVault RDS"
  subnet_ids  = [
    aws_subnet.private.id,
    aws_subnet.private_b.id,
  ]
  tags = {
    Name    = "${var.project_name}-db-subnet-group"
    Project = var.project_name
  }
}

resource "aws_db_parameter_group" "main" {
  name        = "${var.project_name}-pg16-v2"
  family      = "postgres16"
  description = "ShimonVault PostgreSQL 16 logical replication enabled"

  # Enable logical replication so proj-ubuntu01 can subscribe as a read replica.
  # This is required for the on-prem read replica to receive WAL changes from RDS.
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # wal_level is automatically set to logical when rds.logical_replication = 1
  # max_replication_slots: how many replication slots can exist simultaneously
  parameter {
    name         = "max_replication_slots"
    value        = "5"
    apply_method = "pending-reboot"
  }

  # max_wal_senders: how many simultaneous WAL sender processes
  parameter {
    name         = "max_wal_senders"
    value        = "5"
    apply_method = "pending-reboot"
  }

  tags = {
    Name    = "${var.project_name}-pg16"
    Project = var.project_name
  }
}

resource "aws_db_instance" "main" {
  identifier        = "${var.project_name}-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  # Free tier settings
  multi_az                = false
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 1
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  tags = {
    Name    = "${var.project_name}-db"
    Project = var.project_name
  }
}

output "rds_endpoint" {
  description = "RDS endpoint — used in app .env as WRITE_DB_URL"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  value = aws_db_instance.main.port
}
