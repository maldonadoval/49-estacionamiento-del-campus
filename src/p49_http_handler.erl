-module(p49_http_handler).

-export([init/2]).

init(Req0, Opts) ->
    try
        Req = despachar(Opts, Req0),
        {ok, Req, #{}}
    catch
        Clase:Razon:Traza ->
            logger:error("error en API ~p: ~p:~p ~p",
                         [Opts, Clase, Razon, Traza],
                         #{modulo => ?MODULE}),
            ReqError = json(Req0, 500, #{error => error_interno}),
            {ok, ReqError, #{}}
    end.

despachar(metricas, Req) ->
    metricas_respuesta(Req);
despachar(favicon, Req) ->
    cowboy_req:reply(204, #{}, <<>>, Req);
despachar(no_encontrado, Req) ->
    json(Req, 404, #{error => recurso_no_encontrado});
despachar(catalogo, Req) ->
    json(Req, 200, p49_estacionamiento_del_campus_server:catalogo());
despachar(mapa, Req) ->
    Edificio = qs(Req, <<"edificio">>, <<"E1">>),
    respuesta(Req, p49_estacionamiento_del_campus_server:mapa(Edificio));
despachar(recomendaciones, Req) ->
    con_cuerpo(Req, fun(Cuerpo, Req1) ->
        Edificio = maps:get(<<"edificio">>, Cuerpo, <<"E1">>),
        Tipo = maps:get(<<"tipo_usuario">>, Cuerpo, <<"alumno">>),
        Placa = maps:get(<<"placa">>, Cuerpo, <<"">>),
        respuesta(Req1, p49_estacionamiento_del_campus_server:recomendar(
                          Edificio, Tipo, Placa), 201)
    end);
despachar(alternativa, Req) ->
    con_cuerpo(Req, fun(Cuerpo, Req1) ->
        ReservaId = binding(Req1, id),
        CajonId = maps:get(<<"cajon_id">>, Cuerpo, <<"">>),
        Tipo = maps:get(<<"tipo_usuario">>, Cuerpo, <<"alumno">>),
        ObjetivoId = maps:get(<<"objetivo_id">>, Cuerpo, <<"">>),
        respuesta(Req1, p49_estacionamiento_del_campus_server:alternativa(
                          ReservaId, CajonId, Tipo, ObjetivoId))
    end);
despachar(confirmar, Req) ->
    con_cuerpo(Req, fun(Cuerpo, Req1) ->
        ReservaId = binding(Req1, id),
        CajonId = maps:get(<<"cajon_id">>, Cuerpo, <<"">>),
        respuesta(Req1, p49_estacionamiento_del_campus_server:confirmar(
                          ReservaId, CajonId))
    end);
despachar(cancelar, Req) ->
    con_cuerpo(Req, fun(Cuerpo, Req1) ->
        ReservaId = binding(Req1, id),
        CajonId = maps:get(<<"cajon_id">>, Cuerpo, <<"">>),
        respuesta(Req1, p49_estacionamiento_del_campus_server:cancelar(
                          ReservaId, CajonId))
    end);
despachar(estacionamiento_entrada, Req) ->
    con_cuerpo(Req, fun(Cuerpo, Req1) ->
        Placa = maps:get(<<"placa">>, Cuerpo, <<"">>),
        CajonId = maps:get(<<"cajon_id">>, Cuerpo, <<"">>),
        respuesta(Req1, p49_estacionamiento_del_campus_server:entrada(
                          Placa, CajonId), 201)
    end);
despachar(estacionamiento_salida, Req) ->
    con_cuerpo(Req, fun(Cuerpo, Req1) ->
        Placa = maps:get(<<"placa">>, Cuerpo, <<"">>),
        CajonId = maps:get(<<"cajon_id">>, Cuerpo, <<"">>),
        respuesta(Req1, p49_estacionamiento_del_campus_server:salida(
                          Placa, CajonId))
    end);
despachar(estacionamiento_placa, Req) ->
    Placa = binding(Req, placa),
    respuesta(Req, p49_estacionamiento_del_campus_server:estado_placa(Placa));
despachar(admin_sesion, Req) ->
    con_cuerpo(Req, fun(Cuerpo, Req1) ->
        Pin = maps:get(<<"pin">>, Cuerpo, <<"">>),
        case p49_registro:nuevo_token(Pin) of
            {ok, Token, Expira} ->
                json(Req1, 200, #{token => Token, expira_en => Expira});
            {error, pin_invalido} ->
                json(Req1, 401, #{error => pin_invalido,
                                  mensaje => <<"PIN incorrecto">>})
        end
    end);
despachar(admin_estado, Req) ->
    con_admin(Req, fun(Req1) ->
        json(Req1, 200, p49_estacionamiento_del_campus_server:admin_estado())
    end);
despachar(admin_zona, Req) ->
    con_admin(Req, fun(Req1) ->
        con_cuerpo(Req1, fun(Cuerpo, Req2) ->
            ZonaId = binding(Req2, id),
            Estado = maps:get(<<"estado">>, Cuerpo, <<"">>),
            respuesta(Req2, p49_estacionamiento_del_campus_server:
                              admin_zona_estado(ZonaId, Estado))
        end)
    end);
despachar(admin_cajones, Req) ->
    con_admin(Req, fun(Req1) ->
        ZonaId = qs(Req1, <<"zona">>, <<"Z1">>),
        respuesta(Req1, p49_estacionamiento_del_campus_server:admin_cajones(
                          ZonaId))
    end);
despachar(admin_cajon, Req) ->
    con_admin(Req, fun(Req1) ->
        con_cuerpo(Req1, fun(Cuerpo, Req2) ->
            CajonId = binding(Req2, id),
            Estado = maps:get(<<"estado">>, Cuerpo, <<"">>),
            Accion = maps:get(<<"accion">>, Cuerpo, <<"">>),
            Motivo = maps:get(<<"motivo">>, Cuerpo,
                              <<"Actualizacion administrativa">>),
            Resultado = case Accion of
                            <<"liberar">> ->
                                {liberar,
                                 p49_estacionamiento_del_campus_server:
                                     admin_cajon_liberar(CajonId, Motivo)};
                            _ ->
                                {estado,
                                 p49_estacionamiento_del_campus_server:
                                     admin_cajon_estado(CajonId, Estado,
                                                        Motivo)}
                        end,
            case Resultado of
                {liberar, ok} ->
                    json(Req2, 200, #{ok => true, cajon_id => CajonId,
                                      estado => <<"libre">>});
                {liberar, {error, Error}} ->
                    json(Req2, 409, #{error => Error});
                {estado, ok} ->
                    json(Req2, 200, #{ok => true, cajon_id => CajonId,
                                      estado => Estado});
                {estado, {error, Error}} ->
                    json(Req2, 409, #{error => Error});
                {_, Otro} ->
                    json(Req2, 200, #{ok => true, resultado => Otro})
            end
        end)
    end);
despachar(admin_movimientos, Req) ->
    con_admin(Req, fun(Req1) ->
        Limite = p49_util:entero(qs(Req1, <<"limite">>, <<"50">>), 50),
        json(Req1, 200, #{movimientos =>
                            p49_estacionamiento_del_campus_server:
                                movimientos(Limite)})
    end);
despachar(admin_incidencias, Req) ->
    case method(Req) of
        <<"POST">> ->
            con_admin(Req, fun(Req1) ->
                con_cuerpo(Req1, fun(Cuerpo, Req2) ->
                    Tipo = maps:get(<<"tipo">>, Cuerpo, <<"incidencia_manual">>),
                    Datos = maps:get(<<"datos">>, Cuerpo, #{}),
                    p49_estacionamiento_del_campus_server:
                        registrar_incidencia(Tipo, Datos),
                    json(Req2, 201, #{ok => true})
                end)
            end);
        _ ->
            con_admin(Req, fun(Req1) ->
                Limite = p49_util:entero(qs(Req1, <<"limite">>, <<"30">>), 30),
                json(Req1, 200, #{incidencias =>
                                    p49_estacionamiento_del_campus_server:
                                        incidencias(Limite)})
            end)
    end;
despachar(admin_simulacion, Req) ->
    con_admin(Req, fun(Req1) ->
        con_cuerpo(Req1, fun(Cuerpo, Req2) ->
            respuesta(Req2, p49_estacionamiento_del_campus_server:
                              simular(Cuerpo))
        end)
    end);
despachar(admin_escenario, Req) ->
    con_admin(Req, fun(Req1) ->
        respuesta(Req1, p49_estacionamiento_del_campus_server:escenario())
    end);
despachar(admin_diagnostico, Req) ->
    con_admin(Req, fun(Req1) ->
        json(Req1, 200, p49_estacionamiento_del_campus_server:diagnostico())
    end).

respuesta(Req, {ok, Valor}) -> json(Req, 200, Valor);
respuesta(Req, {error, Motivo}) -> error_respuesta(Req, Motivo);
respuesta(Req, ok) -> json(Req, 200, #{ok => true}).

respuesta(Req, {ok, Valor}, Status) -> json(Req, Status, Valor);
respuesta(Req, {error, Motivo}, _Status) -> error_respuesta(Req, Motivo);
respuesta(Req, ok, _Status) -> json(Req, 200, #{ok => true}).

error_respuesta(Req, sin_disponibilidad) ->
    json(Req, 409, #{error => sin_disponibilidad,
                     mensaje => <<"No hay cajones compatibles disponibles">>});
error_respuesta(Req, sin_alternativa) ->
    json(Req, 409, #{error => sin_alternativa,
                     mensaje => <<"No hay otra opcion disponible">>});
error_respuesta(Req, reserva_no_encontrada) ->
    json(Req, 404, #{error => reserva_no_encontrada});
error_respuesta(Req, placa_ya_reservada) ->
    json(Req, 409, #{error => placa_ya_reservada,
                     mensaje => <<"La placa ya tiene un cajon en el campus">>});
error_respuesta(Req, reserva_ya_confirmada) ->
    json(Req, 409, #{error => reserva_ya_confirmada});
error_respuesta(Req, sin_reserva_confirmada) ->
    json(Req, 409, #{error => sin_reserva_confirmada,
                     mensaje => <<"Primero reserva y confirma un cajon">>});
error_respuesta(Req, reserva_no_confirmada) ->
    json(Req, 409, #{error => reserva_no_confirmada,
                     mensaje => <<"La reserva aun no esta confirmada">>});
error_respuesta(Req, sin_estacionamiento_activo) ->
    json(Req, 409, #{error => sin_estacionamiento_activo,
                     mensaje => <<"La placa no tiene un cajon ocupado">>});
error_respuesta(Req, placa_no_coincide) ->
    json(Req, 409, #{error => placa_no_coincide,
                     mensaje => <<"El cajon pertenece a otra placa">>});
error_respuesta(Req, cajon_fuera_de_servicio) ->
    json(Req, 409, #{error => cajon_fuera_de_servicio,
                     mensaje => <<"El cajon esta fuera de servicio">>});
error_respuesta(Req, Motivo) ->
    json(Req, 422, #{error => Motivo}).

con_admin(Req, Fun) ->
    Token = cowboy_req:header(<<"x-admin-token">>, Req),
    case Token =/= undefined andalso p49_registro:validar_token(Token) of
        true -> Fun(Req);
        false -> json(Req, 401,
                      #{error => no_autorizado,
                        mensaje => <<"Se requiere el PIN de administracion">>})
    end.

con_cuerpo(Req, Fun) ->
    {Cuerpo, Req1} = leer_cuerpo(Req),
    case p49_json:decode(Cuerpo) of
        {ok, Mapa} when is_map(Mapa) -> Fun(Mapa, Req1);
        _ -> json(Req1, 400, #{error => json_invalido})
    end.

leer_cuerpo(Req) ->
    leer_cuerpo(Req, <<>>).

leer_cuerpo(Req, Acc) ->
    case cowboy_req:read_body(Req, #{length => 2000000}) of
        {ok, Datos, Req1} -> {<<Acc/binary, Datos/binary>>, Req1};
        {more, Datos, Req1} -> leer_cuerpo(Req1, <<Acc/binary, Datos/binary>>)
    end.

%% cowboy_router entrega las claves de bindings como atomos (id, zona...).
binding(Req, Nombre) ->
    maps:get(Nombre, cowboy_req:bindings(Req), <<"">>).

method(Req) -> cowboy_req:method(Req).

qs(Req, Clave, Default) ->
    try
        proplists:get_value(Clave, cowboy_req:parse_qs(Req), Default)
    catch
        _:_ -> Default
    end.

json(Req, Status, Termino) ->
    cowboy_req:reply(Status,
                     #{<<"content-type">> => <<"application/json; charset=utf-8">>,
                       <<"cache-control">> => <<"no-store">>},
                     p49_json:encode(Termino), Req).

metricas_respuesta(Req) ->
    M = p49_estacionamiento_del_campus_server:metricas(),
    Resumen = maps:get(resumen, M),
    Zonas = maps:get(zonas, M),
    Contadores = maps:get(contadores, M),
    Lineas = [
      "# HELP p49_cajones_total Cajones del campus\n",
      "# TYPE p49_cajones_total gauge\n",
      linea("p49_cajones_total", maps:get(total, Resumen)),
      linea("p49_cajones_libres", maps:get(libres, Resumen)),
      linea("p49_cajones_reservados", maps:get(reservados, Resumen)),
      linea("p49_cajones_ocupados", maps:get(ocupados, Resumen)),
      linea("p49_cajones_fuera_servicio", maps:get(fuera_servicio, Resumen)),
      linea("p49_ocupacion_porcentaje", maps:get(porcentaje_ocupacion, Resumen)),
      "# HELP p49_ocupacion_por_zona Porcentaje de ocupacion por zona\n",
      "# TYPE p49_ocupacion_por_zona gauge\n",
      [io_lib:format("p49_ocupacion_por_zona{zona=\"~s\"} ~p~n",
                     [maps:get(zona, Z), maps:get(porcentaje_ocupacion, Z)])
       || Z <- Zonas],
      "# HELP p49_solicitudes_total Solicitudes de recomendacion\n",
      "# TYPE p49_solicitudes_total counter\n",
      linea("p49_solicitudes_total", maps:get(solicitudes, Contadores, 0)),
      linea("p49_reservas_total", maps:get(reservas, Contadores, 0)),
      linea("p49_confirmadas_total", maps:get(confirmadas, Contadores, 0)),
      linea("p49_entradas_total", maps:get(entradas, Contadores, 0)),
      linea("p49_salidas_total", maps:get(salidas, Contadores, 0)),
      linea("p49_rechazos_total", maps:get(rechazos, Contadores, 0)),
      linea("p49_simulaciones_total", maps:get(simulaciones, Contadores, 0)),
      linea("p49_simulaciones_rechazadas_total",
            maps:get(simulaciones_rechazadas, Contadores, 0)),
      linea("p49_memoria_bytes", maps:get(memoria_total, M, 0))
    ],
    cowboy_req:reply(200,
                     #{<<"content-type">> =>
                           <<"text/plain; version=0.0.4; charset=utf-8">>},
                     iolist_to_binary(Lineas), Req).

linea(Nombre, Valor) ->
    io_lib:format("~s ~p~n", [Nombre, Valor]).
