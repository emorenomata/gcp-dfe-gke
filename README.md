# Guía de Pruebas: GKE Design for Flexibility and Efficiency (DFE) con `ComputeClass`

Esta guía documenta la arquitectura, comandos `gcloud`, manifiestos de Kubernetes (`ComputeClass` y `Deployments`) y el código equivalente en **Terraform** para desplegar un clúster GKE Regional y Privado siguiendo las mejores prácticas de **Obtainability (Obtención de capacidad)** para un mayor grado de obtención de recursos de manera automática

---

## 1. Arquitectura y Flujo de Obtainability

El problema clásico al crear un clúster GKE Standard es el **"huevo y la gallina"**:
1. El recurso `ComputeClass` es un CRD de Kubernetes (requiere que el Control Plane ya exista para aplicarse con `kubectl`).
2. Si creamos el clúster pidiendo directamente nodos grandes (ej. 4 vCPUs / 16 GB RAM en las 3 zonas) y hay un *stockout* en la región, el comando `gcloud container clusters create` fallará antes de poder configurar el `ComputeClass`.

### Solución Implementada
1. **Crear Clúster GKE Regional Privado**: Se usa un pool bootstrap mínimo (`e2-micro`, `min-nodes=0`) y acceso por DNS (`--enable-dns-access`).
2. **Aplicar `ComputeClass` `default`**: Con cascada de prioridades (`n4` -> `c3` -> `n2` -> `e2`), `minCores: 4`, `minMemoryGb: 16` y `nodePoolAutoCreation: enabled: true`.
3. **Eliminar `default-pool` (`e2-micro`)**: Los pods del sistema quedan `Pending` e inmediatamente disparan la auto-creación del Node Pool en la primera familia disponible (`n4`).
4. **Distribución Zonal**: Mediante `podAntiAffinity` en `topology.kubernetes.io/zone`, forzamos 1 nodo en cada una de las 3 zonas.
5. **Fallback Automático**: Si `n4` se queda sin stock al escalar, GKE crea automáticamente un Node Pool adicional en la siguiente prioridad (`c3`, luego `n2`, luego `e2`).

---

## 2. Estructura de Archivos del Proyecto

- `provision-gke-dfe.sh`: Script principal de creación con `gcloud` y `kubectl`.
- `manifests/01-computeclass-default.yaml`: Definición del `ComputeClass` `default` con cascada `n4` -> `c3` -> `n2` -> `e2` y `activeMigration`.
- `manifests/02-zone-spread-deployment.yaml`: Deployment con `podAntiAffinity` zonal para distribuir 1 nodo por zona (3 nodos en total).
- `manifests/03-fallback-test.yaml`: Escenario de prueba que simula falta de capacidad en `n4` y fuerza la creación automática de un Node Pool `c3`.
- `terraform/`: Código completo equivalente en Terraform (`versions.tf`, `variables.tf`, `main.tf`).

---

## 3. Información Adicional: Activación de DFE y `ComputeClass` en Clústeres GKE Existentes

Es posible habilitar estas configuraciones en caliente sobre un clúster GKE que ya está en operación (*zero downtime*), sin afectar los pods actuales ni el node pool existente, para que cualquier crecimiento futuro siga las reglas de `ComputeClass`.

### 3.1 Requisitos y Condiciones Previas
1. **Versión de GKE:**
   * **GKE `1.30.3-gke.1451000` o superior** para usar `ComputeClass` personalizados con auto-creación de node pools (`nodePoolAutoCreation: enabled: true`).
   * **GKE `1.31.1-gke.2105000` o superior** para activar el `ComputeClass` `default` a nivel global del clúster (`--enable-default-compute-class`) y definir reglas de tamaño mínimo (`minCores`, `minMemoryGb`).
2. **Red y Permisos:**
   * Espacio suficiente de direcciones IP en la subred VPC del clúster para alojar los nuevos nodos.
   * Permisos IAM de la cuenta de servicio de los nodos configurados correctamente.

---

### 3.2 Estrategia A: Adopción Global con el `ComputeClass` `default`
Con esta opción, los pods que ya están corriendo permanecen en el node pool actual sin reiniciarse, pero **cualquier pod nuevo o escalamiento futuro** será aprovisionado automáticamente bajo las reglas del `ComputeClass` `default`.

#### Paso 1: Crear el recurso `ComputeClass` `default` en el clúster existente
```bash
cat <<EOF | kubectl apply -f -
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: default
spec:
  nodePoolAutoCreation:
    enabled: true
  whenUnsatisfiable: ScaleUpAnyway
  activeMigration:
    optimizeRulePriority: true
  autoscalingPolicy:
    consolidationDelayMinutes: 5
    consolidationThreshold: 70
  priorities:
    - machineFamily: n4
      minCores: 4
      minMemoryGb: 16
    - machineFamily: c3
      minCores: 4
      minMemoryGb: 16
    - machineFamily: n2
      minCores: 4
      minMemoryGb: 16
    - machineFamily: e2
      minCores: 4
      minMemoryGb: 16
EOF
```

#### Paso 2: Actualizar el clúster para habilitar el `ComputeClass` por defecto
```bash
gcloud container clusters update TU_CLUSTER_EXISTENTE \
  --region="TU_REGION" \
  --project="TU_PROYECTO" \
  --enable-default-compute-class \
  --autoscaling-profile="optimize-utilization"
```

* **¿Qué pasa si conservas tu `default-pool` original (ej. `e2-medium`)?**
  No es obligatorio borrar el node pool existente. Al activar `--enable-default-compute-class`, GKE inyecta automáticamente `nodeSelector: cloud.google.com/compute-class: default` a los pods nuevos. Como el `default-pool` original no tiene esa etiqueta ni cumple con los recursos del `ComputeClass`, GKE lo ignora para nuevas cargas y crea automáticamente los nuevos node pools (`n4`, `c3`, etc.). Si deseas incluir tu node pool actual como última opción de respaldo dentro del `ComputeClass`, puedes añadir `- nodepools: ["nombre-de-tu-pool-actual"]` al final de `priorities:`.

---

### 3.3 Estrategia B: Adopción Gradual por Namespace o por Workload (Sin tocar la configuración global)
Si prefieres no modificar el comportamiento por defecto de todo el clúster productivo, no necesitas ejecutar `gcloud container clusters update`:

1. **Aplicar un `ComputeClass` con nombre personalizado** (ej. `dfe-high-obtainability`):
   ```yaml
   apiVersion: cloud.google.com/v1
   kind: ComputeClass
   metadata:
     name: dfe-high-obtainability
   spec:
     nodePoolAutoCreation:
       enabled: true
     whenUnsatisfiable: ScaleUpAnyway
     priorities:
       - machineFamily: n4
         minCores: 4
         minMemoryGb: 16
       - machineFamily: c3
         minCores: 4
         minMemoryGb: 16
       - machineFamily: e2
         minCores: 4
         minMemoryGb: 16
   ```
2. **Activarlo únicamente para un Namespace específico**:
   ```bash
   kubectl label namespace mi-namespace cloud.google.com/default-compute-class=dfe-high-obtainability
   ```
   **O pedirlo directamente en el manifiesto de un Deployment específico**:
   ```yaml
   spec:
     template:
       spec:
         nodeSelector:
           cloud.google.com/compute-class: dfe-high-obtainability
   ```

---

### 3.4 Detalle del Parámetro `--autoscaling-profile="optimize-utilization"` y Limpieza Automática

Cuando un node pool auto-creado por `ComputeClass` (por ejemplo, un pool de fallback `c3`) queda sin pods porque se eliminó el deployment o bajó el tráfico, **tanto los nodos como el node pool completo se eliminan de manera 100% automática**.

El parámetro `--autoscaling-profile="optimize-utilization"` controla la agresividad con la que el **Cluster Autoscaler** realiza esa reducción (*scale-down* y *bin-packing*):

| Aspecto | `balanced` (Valor por defecto en GKE) | `optimize-utilization` (Recomendado para DFE) |
| :--- | :--- | :--- |
| **Objetivo** | Conservador: mantiene holgura de nodos por si llegan más pods pronto. | **Eficiencia de costos**: compacta pods y apaga nodos sobrantes lo antes posible. |
| **Velocidad de Scale-Down** | Espera ~10 minutos antes de evaluar la eliminación de un nodo subutilizado. | Actúa rápidamente en pocos minutos cuando detecta que los pods caben en otros nodos. |
| **Interacción con `ComputeClass`** | Tarda más en drenar y eliminar pools temporales de fallback (`c3`/`n2`). | En combinación con `autoscalingPolicy.consolidationDelayMinutes` y `consolidationThreshold`, drena nodos subutilizados y elimina el node pool vacío automáticamente. |

* **Cuándo usar `optimize-utilization`:** En arquitecturas de microservicios *stateless* o cargas tolerantes a reubicación donde se busca que los pools dinámicos de `ComputeClass` escalen a cero rápidamente cuando no se requieren.
* **Cuándo mantener `balanced`:** En clústeres existentes con cargas sensibles a la reubicación frecuente de pods que aún no tengan `PodDisruptionBudget` (PDB) configurado.

---

### 3.5 Comandos Útiles de Inspección y Monitoreo
```bash
# 1. Listar los ComputeClasses activos en el clúster
kubectl get computeclass

# 2. Ver el detalle completo y eventos del ComputeClass 'default'
kubectl describe computeclass default

# 3. Ver qué ComputeClass, tipo de instancia y zona tiene cada nodo
kubectl get nodes -L cloud.google.com/compute-class,node.kubernetes.io/instance-type,topology.kubernetes.io/zone

# 4. Verificar qué ComputeClass fue asignado a cada Pod
kubectl get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,COMPUTE_CLASS:.spec.nodeSelector."cloud\.google\.com/compute-class"
```
