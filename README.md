# Estacionamiento del Campus

Sistema de gestión de estacionamientos universitarios desarrollado en Erlang/OTP.

## Funcionalidades

- Consulta de disponibilidad de estacionamientos.
- Recomendación y reserva de cajones.
- Registro de entradas y salidas.
- Administración de estacionamientos y cajones.
- Control de incidencias y movimientos.
- Simulación de solicitudes concurrentes.
- Diagnóstico del nodo Erlang.

## Tecnologías

- Erlang/OTP 27
- Rebar3
- Cowboy
- HTML, CSS y JavaScript
- EUnit

## Requisitos

- Erlang/OTP 27 o compatible.
- Rebar3.

## Instalación y ejecución

Clonar el repositorio:

```bash
git clone https://github.com/maldonadoval/49-estacionamiento-del-campus.git
cd 49-estacionamiento-del-campus
```

Compilar el proyecto:

```bash
rebar3 compile
```

Iniciar la aplicación:

```bash
rebar3 shell
```

Abrir en el navegador:

http://localhost:8080

## Pruebas

Ejecutar las pruebas automatizadas:

```bash
rebar3 eunit
```

El proyecto incluye pruebas de reservas, entradas, salidas, concurrencia, administración y tolerancia a fallos.

## Configuración de demostración

- Puerto HTTP: 8080.
- PIN administrativo de demostración: 050618.

Los valores de demostración deben modificarse antes de un despliegue real.

## Evidencias

Las capturas de ejecución y pruebas se encuentran en la carpeta `evidencias/`.

## Diseño de interfaz

El prototipo visual fue desarrollado con Google Stitch.

## Autoría

Proyecto académico número 49: Estacionamiento del Campus.
