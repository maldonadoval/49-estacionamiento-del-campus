-module(p49_config).
-export([app/0, admin_pin/0, reserva_ttl/0, http_port/0, http_enabled/0,
         seed_ocupacion/0, edificios/0, zonas/0, edificio/1, zona/1,
         zonas_recomendadas/1, distancia/2, tipos_usuario/0, tipo_valido/1,
         tipos_compatibles/1, cajones_zona/1, cajon_id/2, zona_de_cajon/1,
         numero_de_cajon/1, estado_inicial/2, zona_atom/1, total_cajones/0,
         placa_valida/1]).

app() -> p49_estacionamiento_del_campus.

admin_pin() ->
    case os:getenv("P49_ADMIN_PIN") of
        false ->
            p49_util:bin(application:get_env(app(), admin_pin, <<"050618">>));
        Valor ->
            p49_util:bin(Valor)
    end.

reserva_ttl() ->
    application:get_env(app(), reserva_ttl_seg, 600).

http_port() ->
    application:get_env(app(), http_port, 8080).

http_enabled() ->
    application:get_env(app(), http_enabled, true).

seed_ocupacion() ->
    application:get_env(app(), seed_ocupacion, true).

edificios() ->
    [
     #{id => <<"E1">>, nombre => <<"Edificio 1">>,
       descripcion => <<"Aulas y laboratorios">>,
       zonas => [<<"Z1">>, <<"Z2">>],
       distancias => #{<<"Z1">> => 3, <<"Z2">> => 5,
                       <<"Z3">> => 8, <<"Z4">> => 10}},
     #{id => <<"E2">>, nombre => <<"Edificio 2">>,
       descripcion => <<"Docencia y posgrado">>,
       zonas => [<<"Z1">>, <<"Z4">>],
       distancias => #{<<"Z1">> => 4, <<"Z2">> => 7,
                       <<"Z3">> => 7, <<"Z4">> => 3}},
     #{id => <<"E3">>, nombre => <<"Edificio 3">>,
       descripcion => <<"Ingenierias">>,
       zonas => [<<"Z2">>, <<"Z3">>],
       distancias => #{<<"Z1">> => 7, <<"Z2">> => 3,
                       <<"Z3">> => 4, <<"Z4">> => 8}},
     #{id => <<"E4">>, nombre => <<"Edificio 4">>,
       descripcion => <<"Ciencias basicas">>,
       zonas => [<<"Z3">>, <<"Z4">>],
       distancias => #{<<"Z1">> => 9, <<"Z2">> => 8,
                       <<"Z3">> => 3, <<"Z4">> => 4}},
     #{id => <<"E5">>, nombre => <<"Edificio 5">>,
       descripcion => <<"Biblioteca y servicios">>,
       zonas => [<<"Z1">>, <<"Z3">>],
       distancias => #{<<"Z1">> => 4, <<"Z2">> => 8,
                       <<"Z3">> => 5, <<"Z4">> => 8}},
     #{id => <<"E6">>, nombre => <<"Edificio 6">>,
       descripcion => <<"Vinculacion y extension">>,
       zonas => [<<"Z2">>, <<"Z4">>],
       distancias => #{<<"Z1">> => 8, <<"Z2">> => 4,
                       <<"Z3">> => 8, <<"Z4">> => 3}}
    ].

zonas() ->
    [
     #{id => <<"Z1">>, corto => <<"Z1">>, nombre => <<"Estacionamiento 1">>,
       total => 375, referencia => <<"Cerca de los edificios 1, 2 y 5">>},
     #{id => <<"Z2">>, corto => <<"Z2">>, nombre => <<"Estacionamiento 2">>,
       total => 375, referencia => <<"Cerca de los edificios 1, 3 y 6">>},
     #{id => <<"Z3">>, corto => <<"Z3">>, nombre => <<"Estacionamiento 3">>,
       total => 375, referencia => <<"Cerca de los edificios 3, 4 y 5">>},
     #{id => <<"Z4">>, corto => <<"Z4">>, nombre => <<"Estacionamiento 4">>,
       total => 375, referencia => <<"Cerca de los edificios 2, 4 y 6">>}
    ].

edificio(Id) ->
    case [E || E <- edificios(), maps:get(id, E) =:= Id] of
        [E | _] -> {ok, E};
        [] -> {error, edificio_no_encontrado}
    end.

zona(Id) ->
    case [Z || Z <- zonas(), maps:get(id, Z) =:= Id] of
        [Z | _] -> {ok, Z};
        [] -> {error, zona_no_encontrada}
    end.

zonas_recomendadas(EdificioId) ->
    case edificio(EdificioId) of
        {ok, Edificio} ->
            maps:get(zonas, Edificio);
        {error, _} ->
            [maps:get(id, Z) || Z <- zonas()]
    end.

distancia(EdificioId, ZonaId) ->
    case edificio(EdificioId) of
        {ok, Edificio} ->
            maps:get(ZonaId, maps:get(distancias, Edificio), 10);
        {error, _} ->
            10
    end.

tipos_usuario() ->
    [
     #{id => <<"alumno">>, nombre => <<"Alumno">>,
       descripcion => <<"Cajones generales y de visitante">>},
     #{id => <<"docente">>, nombre => <<"Docente">>,
       descripcion => <<"Cajones de docente y visitante">>},
     #{id => <<"discapacidad">>, nombre => <<"Movilidad reducida">>,
       descripcion => <<"Cajones accesibles reservados">>},
     #{id => <<"moto">>, nombre => <<"Motocicleta">>,
       descripcion => <<"Solo cajones para moto">>},
     #{id => <<"visitante">>, nombre => <<"Visitante">>,
       descripcion => <<"Cajones de visitante">>}
    ].

tipo_valido(Tipo) ->
    lists:any(fun(#{id := Id}) -> Id =:= Tipo end, tipos_usuario()).

tipos_compatibles(<<"alumno">>) -> [<<"alumno">>, <<"visitante">>];
tipos_compatibles(<<"docente">>) -> [<<"docente">>, <<"visitante">>];
tipos_compatibles(<<"discapacidad">>) -> [<<"discapacidad">>];
tipos_compatibles(<<"moto">>) -> [<<"moto">>];
tipos_compatibles(<<"visitante">>) -> [<<"visitante">>];
tipos_compatibles(_) -> [].

cajones_zona(ZonaId) ->
    [#{id => cajon_id(ZonaId, Numero),
       zona => ZonaId,
       numero => Numero,
       tipo => tipo_cajon(Numero)}
     || Numero <- lists:seq(1, 375)].

cajon_id(ZonaId, Numero) ->
    iolist_to_binary([ZonaId, $-, string:pad(integer_to_binary(Numero), 3, leading, $0)]).

zona_de_cajon(Id) when is_binary(Id) ->
    case binary:split(Id, <<"-">>) of
        [Zona | _] -> Zona;
        _ -> <<"">>
    end.

numero_de_cajon(Id) when is_binary(Id) ->
    case binary:split(Id, <<"-">>) of
        [_Zona, Numero | _] ->
            try binary_to_integer(Numero)
            catch _:_ -> 0
            end;
        _ -> 0
    end.

tipo_cajon(Numero) when Numero =< 265 -> <<"alumno">>;
tipo_cajon(Numero) when Numero =< 310 -> <<"docente">>;
tipo_cajon(Numero) when Numero =< 340 -> <<"discapacidad">>;
tipo_cajon(Numero) when Numero =< 355 -> <<"moto">>;
tipo_cajon(_Numero) -> <<"visitante">>.

%% Genera estados iniciales reproducibles para que el mapa muestre los
%% cuatro estados desde el primer arranque. En pruebas se desactiva con
%% seed_ocupacion=false.
estado_inicial(ZonaId, Numero) ->
    case seed_ocupacion() of
        false -> {libre, undefined, undefined};
        true ->
            H = erlang:phash2({campus, ZonaId, Numero}, 1000),
            Edificio = edificio_semilla(H),
            Placa = <<"SIM-", (integer_to_binary(H))/binary>>,
            case H of
                _ when H < 360 ->
                    {ocupado,
                     #{id => undefined, placa => Placa, edificio => Edificio,
                       confirmada => true, entrada_en => p49_util:ahora_seg()},
                     undefined};
                _ when H < 440 ->
                    {reservado,
                     #{id => <<"RES-SEED-", (cajon_id(ZonaId, Numero))/binary>>,
                       placa => Placa, edificio => Edificio,
                       confirmada => true, expira_en => undefined,
                       creada_en => p49_util:ahora_seg()},
                     undefined};
                _ when H < 460 ->
                    {fuera_servicio, undefined, <<"Mantenimiento preventivo">>};
                _ ->
                    {libre, undefined, undefined}
            end
    end.

edificio_semilla(H) ->
    Ids = [maps:get(id, E) || E <- edificios()],
    lists:nth((H rem length(Ids)) + 1, Ids).

zona_atom(ZonaId) ->
    binary_to_atom(<<"p49_zona_", ZonaId/binary>>, utf8).

total_cajones() ->
    lists:sum([maps:get(total, Z) || Z <- zonas()]).

placa_valida(Placa) when is_binary(Placa) ->
    Largo = byte_size(Placa),
    Largo >= 3 andalso Largo =< 12 andalso
        lists:all(fun(C) ->
                          (C >= $A andalso C =< $Z) orelse
                              (C >= $0 andalso C =< $9) orelse C =:= $-
                  end, binary_to_list(Placa));
placa_valida(_) ->
    false.
