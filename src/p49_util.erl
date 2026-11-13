-module(p49_util).
-export([id/1, ahora_ms/0, ahora_seg/0, iso8601/1, bin/1,
         entero/2, limpiar_placa/1, recortar/2, redondear/1]).

id(Prefijo) ->
    Unico = erlang:unique_integer([positive, monotonic]),
    Now = erlang:system_time(microsecond),
    iolist_to_binary([Prefijo, $-,
                      integer_to_binary(Now), $-,
                      integer_to_binary(Unico)]).

ahora_ms() -> erlang:system_time(millisecond).

ahora_seg() -> erlang:system_time(second).

iso8601(Segundos) when is_integer(Segundos) ->
    try
        list_to_binary(calendar:system_time_to_rfc3339(
                         Segundos, [{unit, second}, {offset, "Z"}]))
    catch
        _:_ -> <<"">>
    end.

bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Otro) -> iolist_to_binary(io_lib:format("~p", [Otro])).

entero(B, Default) ->
    try
        binary_to_integer(p49_util:bin(B))
    catch
        _:_ -> Default
    end.

%% Normaliza una placa: mayusculas, sin espacios y solo A-Z, 0-9 y guion.
limpiar_placa(Bin) when is_binary(Bin) ->
    Mayus = string:uppercase(unicode:characters_to_list(Bin)),
    Limpia = [C || C <- Mayus, (C >= $A andalso C =< $Z) orelse
                              (C >= $0 andalso C =< $9) orelse C =:= $-],
    list_to_binary(Limpia);
limpiar_placa(_) ->
    <<"">>.

recortar(Lista, Max) when is_list(Lista), length(Lista) > Max ->
    lists:sublist(Lista, Max);
recortar(Lista, _Max) ->
    Lista.

redondear(F) when is_float(F) ->
    round(F * 10) / 10;
redondear(I) when is_integer(I) ->
    I.
