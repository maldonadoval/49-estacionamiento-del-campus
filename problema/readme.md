# Problema — Proyecto 49: Estacionamiento del campus

Variante del proyecto 6 (Estacionamiento inteligente) con el campus organizado en
**edificios** y **zonas de estacionamiento**. Cada cajón es un proceso independiente y el
sistema debe sobrevivir a fallas sin perder la coherencia de la ocupación.

## Situación

En horas pico, estudiantes y personal dan vueltas buscando lugar sin saber qué zona tiene
cajones libres. Dos personas llegan al mismo cajón al mismo tiempo, los cajones accesibles
se ocupan sin control y nadie sabe qué edificio se llena primero. Además, el personal de
vigilancia necesita cerrar zonas por mantenimiento y marcar cajones fuera de servicio sin
detener el resto del estacionamiento.

## Objetivo

Construir un sistema Erlang/OTP que:

1. Muestre en tiempo real la disponibilidad por zona y por cajón.
2. Asigne automáticamente un cajón compatible con el edificio y el tipo de usuario.
3. Permita confirmar, cambiar o cancelar una reserva temporal.
4. Garantice que **nunca** haya dos reservas para el mismo cajón.
5. Garantice que una placa tenga **un solo cajón** en todo el campus.
6. Permita a administración cerrar/reaperturar zonas y operar cajones fuera de servicio.
7. Registre movimientos e incidencias y exponga métricas.
8. Se recupere automáticamente de la caída de cajones, zonas o del coordinador.

## Entidades y representación OTP

| Entidad | Representación |
|---|---|
| Cajón | `p49_cajon`, un `gen_statem` por cajón |
| Zona | `p49_zona`, un `gen_server` por zona con la foto agregada |
| Supervisor de zona | `p49_zona_sup`, `rest_for_one` (cajones → zona) |
| Supervisor de cajones | `p49_cajon_sup`, `one_for_one` |
| Campus | `p49_estacionamiento_del_campus_sup`, `rest_for_one` |
| Registro | `p49_registro`, bitácora, contadores y tokens administrativos |
| Coordinador | `p49_estacionamiento_del_campus_server`, flujo de reservas y API |
| Sensores | simulados por la siembra inicial, la API administrativa y las pruebas |

## Modelo

- **6 edificios** (`E1`–`E6`) con dos zonas recomendadas cada uno.
- **4 zonas** (`Z1`, `Z2`, `Z3`, `Z4`) con **375 cajones** cada una. En la interfaz se
  llaman **Estacionamiento 1** a **Estacionamiento 4**.
- **1,500 cajones** en total.
- Tipos: alumno (001–265), docente (266–310), movilidad reducida (311–340),
  motocicleta (341–355) y visitante (356–375) dentro de cada zona.

## Reglas de negocio

- El alumno elige edificio, tipo y placa; **no elige un cajón arbitrario**.
- El backend propone dos cajones compatibles, uno por estacionamiento recomendado; el
  usuario elige una de las dos tarjetas, pero no un número específico.
- Una recomendación temporal dura 10 minutos (`reserva_ttl_seg = 600`) y expira sola.
- Una reserva confirmada se conserva hasta 4 horas o hasta que se libere el cajón.
- Solo la placa que reservó puede ocupar el cajón reservado.
- **Registrar la entrada** exige una reserva confirmada (o que el cajón ya esté ocupado
  por esa placa); pasa el cajón de `reservado` a `ocupado` y guarda `entrada_en`. Es
  idempotente: repetirla no duplica contadores.
- **Registrar la salida** la solicita la misma placa que ocupa el cajón, lo pasa a `libre`
  y calcula la duración de la estancia.
- Una placa solo puede tener un cajón en todo el campus. Una reserva temporal sin
  confirmar puede reemplazarse por una nueva solicitud de la misma placa; una reserva
  confirmada o un cajón ocupado bloquean una segunda solicitud.
- Los cajones accesibles solo se asignan a usuarios de tipo `discapacidad`.
- No se puede marcar fuera de servicio un cajón ocupado.
- Al cerrar una zona se liberan sus reservas pendientes; los cajones ocupados permanecen
  ocupados hasta que se liberen.
- La asignación de un cajón es atómica: la decide el proceso del cajón, no la zona ni el
  coordinador.

## Flujo del alumno

```
1. Elige edificio, tipo de usuario y placa.
2. POST /api/recomendaciones
   └─ el coordinador valida la placa y consulta las zonas recomendadas.
   └─ el cajón reserva con un reserva_id único y responde.
3. El alumno confirma:
   POST /api/recomendaciones/:id/confirmar
   └─ el cajón verifica que la reserva siga vigente y sea suya.
4. O elige la otra tarjeta recomendada (la interfaz muestra dos, una por estacionamiento):
   POST /api/recomendaciones/:id/alternativa  {cajon_id, objetivo_id?}
   └─ se aparta el nuevo cajón y solo entonces se libera el anterior.
   └─ con objetivo_id elige una de las opciones mostradas; si ya se ocupó,
      el backend cae en la siguiente mejor.
5. O cancela:
   POST /api/recomendaciones/:id/cancelar
6. Al llegar, registra la entrada:
   POST /api/estacionamientos/entrada  {placa}
   └─ valida la reserva confirmada y ocupa el cajón.
7. Al retirarse, registra la salida:
   POST /api/estacionamientos/salida  {placa}
   └─ libera el cajón y calcula la duración.
8. Puede consultar su estado con:
   GET /api/estacionamientos/:placa
```

## Flujo administrativo

```
1. POST /api/admin/sesion  {pin:"050618"}
   └─ el backend valida el PIN y devuelve un token de 30 minutos.
2. Todas las llamadas administrativas envían x-admin-token.
3. El panel muestra totales, zonas, movimientos, incidencias y métricas.
4. Cerrar/Reabrir zona: POST /api/admin/zonas/:id
5. Mantenimiento de cajón: POST /api/admin/cajones/:id
6. Simulación concurrente: POST /api/admin/simulacion
7. Escenario de 1,200 autos: POST /api/admin/escenario
```

## Fuera de alcance

- Pagos y tarifas.
- Lectura real de placas con cámaras o sensores físicos.
- Persistencia en base de datos; la ocupación inicial se siembra de forma determinista.
- Usuarios, roles y autenticación de alumnos.
- Consistencia entre múltiples nodos (el proyecto es de un solo nodo).
- Notificaciones push o correo.

## Criterios de aceptación

- [x] 120 recomendaciones simultáneas generan 120 cajones únicos, sin duplicados.
- [x] Una placa no puede tener dos cajones en el campus.
- [x] Matar un cajón con `exit(Pid, kill)` lo hace reaparecer; la zona restaura el estado
      que conocía y los conteos siguen cuadrando.
- [x] Matar una zona la reinicia leyendo sus 375 cajones; las reservas vivas se conservan.
- [x] Matar el coordinador lo reinicia y el listener HTTP sigue disponible.
- [x] El cajón recomendado no se puede cambiar por un número arbitrario desde el cliente.
- [x] La recomendación ofrece una opción por estacionamiento recomendado; elegir la segunda
      opción respeta exactamente el cajón mostrado y solo acepta opciones del servidor.
- [x] Confirmar una reserva ajena o vencida devuelve error.
- [x] Cerrar una zona impide nuevas reservas en ella y libera las pendientes.
- [x] Un cajón ocupado no puede marcarse fuera de servicio.
- [x] Solo la placa con reserva confirmada puede registrar su entrada; la entrada repetida
      es idempotente y la salida libera el cajón y calcula la duración.
- [x] `/metrics` expone `p49_cajones_*`, `p49_ocupacion_por_zona`, `p49_entradas_total`,
      `p49_salidas_total` y contadores.
- [x] El dashboard se actualiza sin recargar la página mediante `/ws/mapa`.
- [x] La pestaña de administración exige PIN validado por el backend y token de sesión.
- [x] El mapa se muestra compacto y se amplía a los 375 cajones con “Ampliar mapa”.
- [x] La suite eunit pasa completa (14 pruebas).
- [x] El escenario de 1,200 autos termina sin duplicados y con el Estacionamiento 4 (`Z4`)
  reabierto.

## Evidencia de pruebas

| Prueba | Resultado |
|---|---|
| `rebar3 eunit` | 14/14 pruebas |
| Entrada/salida HTTP | recomendar → confirmar → entrada → salida verificado, `ya_registrada` en la segunda entrada |
| Simulación concurrente de 120 | 120 asignadas, 0 duplicados |
| Escenario completo de 1,200 | 593 asignadas, 607 rechazadas, 0 duplicados |
| Caos: cajón, zona y coordinador | Recuperación automática verificada |
| WebSocket `/ws/mapa` | Suscripción y mapa en vivo verificados |

Las instrucciones para ejecutar el proyecto, la API completa y el despliegue están en el
[`README.md`](../README.md) principal.
