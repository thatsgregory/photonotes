terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.9.1"
    }
    archive = {
      source = "hashicorp/archive"
    }
  }
}

provider "yandex" {
  token     = var.token
  folder_id = var.folder_id
  zone      = var.zone
  cloud_id  = var.cloud_id
}

# === 1. СЕТЬ И БЕЗОПАСНОСТЬ ===
resource "yandex_vpc_network" "net" {
  name = "app-network"
}

resource "yandex_vpc_subnet" "subnet" {
  name           = "app-subnet"
  zone           = var.zone
  network_id     = yandex_vpc_network.net.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

resource "yandex_vpc_security_group" "sg" {
  name        = "app-sg"
  network_id  = yandex_vpc_network.net.id

  ingress {
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }

  ingress {
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  ingress {
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 5000
  }
  
  ingress {
    protocol       = "TCP"
    v4_cidr_blocks = ["198.18.232.0/21", "198.18.248.0/21"]
    port           = 30080
  }
  
  ingress {
    protocol          = "ANY"
    predefined_target = "self_security_group"
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# === 2. СЕРВИСНЫЙ АККАУНТ ===
resource "yandex_iam_service_account" "sa" {
  name = "app-sa-${substr(uuid(), 0, 6)}"
}

resource "yandex_resourcemanager_folder_iam_member" "editor" {
  folder_id = var.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "puller" {
  folder_id = var.folder_id
  role      = "container-registry.images.puller"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa_key" {
  service_account_id = yandex_iam_service_account.sa.id
}

# === 3. OBJECT STORAGE ===
resource "yandex_storage_bucket" "bucket" {
  bucket     = "photo-notes-${substr(uuid(), 0, 6)}"
  access_key = yandex_iam_service_account_static_access_key.sa_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_key.secret_key
  
  anonymous_access_flags {
    read = true
    list = false
  }
}

# === 4. YDB ===
resource "yandex_ydb_database_serverless" "db" {
  name      = "photo-db"
  folder_id = var.folder_id
}

resource "time_sleep" "wait_db" {
  create_duration = "90s"
  depends_on      = [yandex_ydb_database_serverless.db]
}

resource "yandex_ydb_table" "table" {
  path              = "notes"
  connection_string = yandex_ydb_database_serverless.db.ydb_full_endpoint
  
  column {
    name = "id"
    type = "Utf8"
  }
  column {
    name = "title"
    type = "Utf8"
  }
  column {
    name = "image_url"
    type = "Utf8"
  }
  
  primary_key = ["id"]
  depends_on  = [time_sleep.wait_db]
}

# === 5. ФУНКЦИЯ ===
data "archive_file" "zip" {
  type        = "zip"
  source_file = "${path.module}/../serverless/handler.py"
  output_path = "${path.module}/function.zip"
}

resource "yandex_function" "func" {
  name               = "s3-logger"
  user_hash          = data.archive_file.zip.output_base64sha256
  runtime            = "python39"
  entrypoint         = "handler.handler"
  memory             = 128
  service_account_id = yandex_iam_service_account.sa.id
  content {
    zip_filename = data.archive_file.zip.output_path
  }
}

resource "yandex_function_trigger" "trigger" {
  name = "s3-trigger"
  function {
    id                 = yandex_function.func.id
    service_account_id = yandex_iam_service_account.sa.id
  }
  object_storage {
    bucket_id    = yandex_storage_bucket.bucket.id
    create       = true
    batch_cutoff = 5
  }
}

# === 6. ВИРТУАЛЬНЫЕ МАШИНЫ ===
data "yandex_compute_image" "coi" {
  family = "container-optimized-image"
}

resource "yandex_compute_instance_group" "ig" {
  name               = "app-ig"
  service_account_id = yandex_iam_service_account.sa.id
  depends_on         = [yandex_resourcemanager_folder_iam_member.editor]
  
  allocation_policy {
    zones = [var.zone]
  }
  
  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
  }
  
  scale_policy {
    fixed_scale {
      size = 2
    }
  }
  
  instance_template {
    platform_id = "standard-v2"
    
    service_account_id = yandex_iam_service_account.sa.id
    
    resources {
      memory = 2
      cores  = 2
    }
    boot_disk {
      initialize_params {
        image_id = data.yandex_compute_image.coi.id
      }
    }
    network_interface {
      network_id         = yandex_vpc_network.net.id
      subnet_ids         = [yandex_vpc_subnet.subnet.id]
      nat                = true
      security_group_ids = [yandex_vpc_security_group.sg.id]
    }
    metadata = {
      user-data = templatefile("${path.module}/cloud-init.yaml", {
        ssh_key          = file(var.ssh_key_path)
        ydb_endpoint = "grpcs://${yandex_ydb_database_serverless.db.ydb_api_endpoint}"
        ydb_db           = yandex_ydb_database_serverless.db.database_path
        bucket           = yandex_storage_bucket.bucket.bucket
        key_id           = yandex_iam_service_account_static_access_key.sa_key.access_key
        key_secret       = yandex_iam_service_account_static_access_key.sa_key.secret_key
        docker_image_url = var.docker_image
      })
    }
  }
  
  application_load_balancer {
    target_group_name = "app-tg"
  }
}

# === 7. БАЛАНСИРОВЩИК (ALB) ===
resource "yandex_alb_backend_group" "bg" {
  name = "app-bg"
  
  http_backend {
    name             = "http"
    weight           = 1
    port             = 5000
    target_group_ids = [yandex_compute_instance_group.ig.application_load_balancer.0.target_group_id]
    
    healthcheck {
      timeout  = "1s"
      interval = "1s"
      http_healthcheck {
        path = "/"
      }
    }
  }
}

resource "yandex_alb_http_router" "router" {
  name = "app-router"
}

resource "yandex_alb_virtual_host" "vh" {
  name           = "app-host"
  http_router_id = yandex_alb_http_router.router.id
  route {
    name = "root"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.bg.id
      }
    }
  }
}

resource "yandex_alb_load_balancer" "lb" {
  name       = "app-lb"
  network_id = yandex_vpc_network.net.id
  security_group_ids = [yandex_vpc_security_group.sg.id]
  
  allocation_policy {
    location {
      zone_id   = var.zone
      subnet_id = yandex_vpc_subnet.subnet.id
    }
  }
  
  listener {
    name = "http"
    endpoint {
      address {
        external_ipv4_address {}
      }
      ports = [80]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.router.id
      }
    }
  }
}

output "ip" {
  value = yandex_alb_load_balancer.lb.listener[0].endpoint[0].address[0].external_ipv4_address[0].address
}
