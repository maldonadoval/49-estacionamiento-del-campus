-module(p49_simulacion).

-export([concurrente/1, escenario/0]).

-define(MAX_SOLICITUDES, 2000).
-define(ESPERA_SIMULACION_MS, 60000).
-define(MAX_RONDAS, 40).
-define(OPCIONES_POR_ZONA, 5).

concurrente(Params) when is_map(Params) ->
    N = limitar(maps:get(<<"solicitudes">>, Params, 120)),
    Edificio = maps:get(<<"edificio">>, Params, <<"E1">>),
    Tipo = maps:get(<<"tipo_usuario">>, Params, <<"alumno">>),
    case {p49_config:edificio(Edificio), p49_config:tipo_valido(Tipo)} of
        {{ok, _}, true} ->
            Solicitudes = [{Edificio, Tipo} || _ <- lists:seq(1, N)],
            ejecutar(Solicitudes, <<"concurrente">>);
        _ ->
            {error, parametros_invalidos}
    end;
concurrente(_) ->
    {error, parametros_invalidos}.

escenario() ->
    Edificios = [maps:get(id, E) || E <- p49_config:edificios()],
    Solicitudes = [solicitud_escenario(I, Edificios) || I <- lists:seq(1, 1200)],
    p49_zona:cerrar(<<"Z4">>),
    p49_registro:movimiento(escenario_iniciado,
                            #{autos => 1200, zona_cerrada => <<"Z4">>}),
    Resultado = ejecutar(Solicitudes, <<"escenario_completo">>),
    p49_zona:abrir(<<"Z4">>),
    p49_registro:incidencia(vehiculo_sin_permiso,
                            #{zona => <<"Z1">>, cajon => <<"Z1-311">>,
                              placa => <<"SIN-PERMISO">>,
                              detalle => <<"Vehiculo en cajon accesible sin acreditacion">>}),
    p49_registro:incidencia(sensor_inconsistente,
                            #{zona => <<"Z2">>, cajon => <<"Z2-120">>,
                              detalle => <<"El sensor reporto libre un cajon que el conteo marco ocupado">>}),
    case Resultado of
        {ok, Base} ->
            {ok, Base#{escenario => #{edificios => 6,
                                      zonas => 4,
                                      cajones => p49_config:total_cajones(),
                                      autos => 1200,
                                      zona_cerrada => <<"Z4">>,
                                      zona_reabierta => true,
                                      incidencias_inyectadas => 2}}};
        Otro ->
            Otro
    end.

solicitud_escenario(I, Edificios) ->
    Edificio = lists:nth((I rem length(Edificios)) + 1, Edificios),
    Tipo = case I rem 100 of
               X when X < 70 -> <<"alumno">>;
               X when X < 80 -> <<"docente">>;
               X when X < 88 -> <<"discapacidad">>;
               X when X < 94 -> <<"moto">>;
               _ -> <<"visitante">>
           end,
    {Edificio, Tipo}.

ejecutar(Solicitudes, Etiqueta) ->
    Inicio = erlang:monotonic_time(millisecond),
    Padre = self(),
    NumSolicitudes = length(Solicitudes),
    [spawn_monitor(fun() ->
                       Resultado = try
                                       intentar_solicitud(Edificio, Tipo,
                                                          Indice, Placa)
                                   catch
                                       C:R -> {error, {C, R}}
                                   end,
                       Padre ! {simulacion_resultado, self(), Resultado}
                   end)
     || {Indice, {Edificio, Tipo}} <- lists:zip(lists:seq(1, NumSolicitudes),
                                                Solicitudes),
        Placa <- [placa_simulada(Indice)]],
    %% Las reservas se conservan hasta que termina la ultima solicitud. Asi
    %% el conteo de duplicados mide de verdad la atomicidad de la reserva y
    %% no reutilizaciones posteriores de cajones liberados.
    Resultados = recolectar(NumSolicitudes, []),
    Fin = erlang:monotonic_time(millisecond),
    Asignadas = [C || {ok, _Zona, C, _ReservaId} <- Resultados],
    Rechazadas = length([1 || {error, _} <- Resultados]),
    Duplicados = length(Asignadas) - length(lists:usort(Asignadas)),
    PorZona = por_zona(Resultados),
    p49_registro:contador(simulaciones, 1),
    p49_registro:contador(simulaciones_solicitudes, NumSolicitudes),
    p49_registro:contador(simulaciones_rechazadas, Rechazadas),
    case Duplicados of
        0 -> ok;
        _ -> p49_registro:incidencia(
               simulacion_con_duplicados,
               #{duplicados => Duplicados, etiqueta => Etiqueta})
    end,
    Muestra = [#{zona => Zona, cajon => Cajon}
               || {ok, Zona, Cajon, _ReservaId}
                      <- lists:sublist(Resultados, 5)],
    liberar_reservas(Resultados, Etiqueta),
    {ok, #{tipo => Etiqueta,
           solicitudes => NumSolicitudes,
           asignadas => length(Asignadas),
           rechazadas => Rechazadas,
           duplicados => Duplicados,
           unicos => length(lists:usort(Asignadas)),
           tiempo_ms => Fin - Inicio,
           por_zona => PorZona,
           muestra => Muestra,
           inicio => p49_util:iso8601(p49_util:ahora_seg()),
           fin => p49_util:iso8601(p49_util:ahora_seg())}}.

recolectar(0, Acc) ->
    Acc;
recolectar(Pendientes, Acc) ->
    receive
        {simulacion_resultado, _Pid, Resultado} ->
            recolectar(Pendientes - 1, [Resultado | Acc])
    after ?ESPERA_SIMULACION_MS ->
        [{error, timeout} | Acc]
    end.

%% Un usuario real reintenta si la recomendacion que recibio quedo obsoleta
%% por otra solicitud concurrente. La simulacion hace lo mismo para medir la
%% asignacion real y no solo la primera ronda de recomendaciones.
intentar_solicitud(Edificio, Tipo, Indice, Placa) ->
    intentar_rondas(?MAX_RONDAS, Edificio, Tipo, Indice, Placa).

intentar_rondas(0, _Edificio, _Tipo, _Indice, _Placa) ->
    {error, sin_disponibilidad};
intentar_rondas(Rondas, Edificio, Tipo, Indice, Placa) ->
    Intento = ?MAX_RONDAS - Rondas,
    Zonas = rotar(zonas_para_intento(Edificio), Indice + Intento),
    case intentar_zonas(Zonas, Edificio, Tipo, Placa) of
        {ok, _Zona, _Cajon, _ReservaId} = Asignada ->
            Asignada;
        {error, _} ->
            timer:sleep(1 + rand:uniform(5)),
            intentar_rondas(Rondas - 1, Edificio, Tipo, Indice, Placa)
    end.

intentar_zonas([], _Edificio, _Tipo, _Placa) ->
    {error, sin_disponibilidad};
intentar_zonas([Zona | Resto], Edificio, Tipo, Placa) ->
    Opciones = p49_zona:recomendar(Zona, Edificio, Tipo),
    case intentar_opciones(lists:sublist(Opciones, ?OPCIONES_POR_ZONA),
                           Zona, Edificio, Placa) of
        {ok, Cajon, ReservaId} -> {ok, Zona, Cajon, ReservaId};
        {error, _} -> intentar_zonas(Resto, Edificio, Tipo, Placa)
    end.

intentar_opciones([], _Zona, _Edificio, _Placa) ->
    {error, no_disponible};
intentar_opciones([Opcion | Resto], Zona, Edificio, Placa) ->
    CajonId = maps:get(cajon_id, Opcion),
    ReservaId = p49_util:id("sim"),
    case p49_zona:reservar(Zona, CajonId, ReservaId, Placa, Edificio) of
        {ok, _Info} ->
            {ok, CajonId, ReservaId};
        {error, _} ->
            intentar_opciones(Resto, Zona, Edificio, Placa)
    end.

liberar_reservas(Resultados, Etiqueta) ->
    [intentar_liberar(Zona, Cajon, ReservaId, Etiqueta)
     || {ok, Zona, Cajon, ReservaId} <- Resultados],
    ok.

intentar_liberar(Zona, Cajon, ReservaId, Etiqueta) ->
    try p49_zona:cancelar(Zona, Cajon, ReservaId, Etiqueta)
    catch _:_ -> ok
    end.

zonas_para_intento(Edificio) ->
    Recomendadas = p49_config:zonas_recomendadas(Edificio),
    Todas = [maps:get(id, Z) || Z <- p49_config:zonas()],
    Recomendadas ++ (Todas -- Recomendadas).

rotar([], _Indice) -> [];
rotar(Lista, Indice) ->
    N = length(Lista),
    {A, B} = lists:split(Indice rem N, Lista),
    B ++ A.

por_zona(Resultados) ->
    lists:foldl(
      fun({ok, Zona, _Cajon, _ReservaId}, Acc) ->
              maps:put(Zona, maps:get(Zona, Acc, 0) + 1, Acc);
         (_, Acc) -> Acc
      end, #{}, Resultados).

limitar(N) when is_integer(N), N > ?MAX_SOLICITUDES -> ?MAX_SOLICITUDES;
limitar(N) when is_integer(N), N > 0 -> N;
limitar(_) -> 1.

placa_simulada(Indice) ->
    Unico = erlang:unique_integer([positive]),
    <<"SIM", (integer_to_binary(Indice))/binary,
      (integer_to_binary(Unico rem 1000))/binary>>.
