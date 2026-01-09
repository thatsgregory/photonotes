variable "token" {
  type        = string
  description = "Yandex Cloud OAuth Token"
  sensitive   = true
}

variable "folder_id" {
  type        = string
  description = "ID каталога"
}

variable "cloud_id" {
  type        = string
  description = "ID облака"
}

variable "zone" {
  type        = string
  default     = "ru-central1-a"
  description = "Зона доступности"
}

variable "ssh_key_path" {
  type        = string
  description = "Путь к публичному SSH ключу"
}

variable "docker_image" {
  type        = string
  description = "Полная ссылка на Docker образ"
}
