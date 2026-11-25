data "google_client_config" "default" {}

# 1. Clúster GKE Regional Privado con Default ComputeClass habilitado
resource "google_container_cluster" "dfe_cluster" {
  provider = google-beta

  name     = var.cluster_name
  project  = var.project_id
  location = var.region

  # Crea el clúster con 1 nodo e2-micro por zona y borra el default-pool inmediatamente
  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    machine_type = "e2-micro"
  }

  release_channel {
    channel = "REGULAR"
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {}

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  # Habilita el acceso por DNS al Control Plane (evita timeouts por IP/Authorized Networks)
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  # Configuración de Autoscaling + Default ComputeClass + Obtainability
  cluster_autoscaling {
    auto_provisioning_defaults {
      management {
        auto_upgrade = true
        auto_repair  = true
      }
    }
    autoscaling_profile           = "OPTIMIZE_UTILIZATION"
    default_compute_class_enabled = true
  }

  deletion_protection = false
}

# 2. Configuración del Provider de Kubernetes usando el DNS Endpoint del clúster
provider "kubernetes" {
  host  = "https://${google_container_cluster.dfe_cluster.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}"
  token = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(
    google_container_cluster.dfe_cluster.master_auth[0].cluster_ca_certificate
  )
}

# 3. Creación automática del ComputeClass 'default'
resource "kubernetes_manifest" "default_compute_class" {
  manifest = {
    apiVersion = "cloud.google.com/v1"
    kind       = "ComputeClass"
    metadata = {
      name = "default"
    }
    spec = {
      nodePoolAutoCreation = {
        enabled = true
      }
      whenUnsatisfiable = "ScaleUpAnyway"
      activeMigration = {
        optimizeRulePriority = true
      }
      autoscalingPolicy = {
        consolidationDelayMinutes = 5
        consolidationThreshold    = 70
      }
      priorities = [
        {
          machineFamily = "n4"
          minCores      = 4
          minMemoryGb   = 16
        },
        {
          machineFamily = "c3"
          minCores      = 4
          minMemoryGb   = 16
        },
        {
          machineFamily = "n2"
          minCores      = 4
          minMemoryGb   = 16
        },
        {
          machineFamily = "e2"
          minCores      = 4
          minMemoryGb   = 16
        }
      ]
    }
  }

  depends_on = [google_container_cluster.dfe_cluster]
}

# 4. (Opcional) Deployment para asegurar 1 nodo por zona desde el inicio
resource "kubernetes_manifest" "zone_spread_deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "zone-spread-app"
      namespace = "default"
    }
    spec = {
      replicas = 3
      selector = {
        matchLabels = {
          app = "zone-spread-app"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "zone-spread-app"
          }
        }
        spec = {
          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchExpressions = [
                      {
                        key      = "app"
                        operator = "In"
                        values   = ["zone-spread-app"]
                      }
                    ]
                  }
                  topologyKey = "topology.kubernetes.io/zone"
                }
              ]
            }
          }
          containers = [
            {
              name  = "pause"
              image = "registry.k8s.io/pause:3.9"
              resources = {
                requests = {
                  cpu    = "500m"
                  memory = "512Mi"
                }
              }
            }
          ]
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.default_compute_class]
}
