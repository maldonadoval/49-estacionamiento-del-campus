-module(p49_json).
-export([encode/1, decode/1]).

%% Codificador/decodificador JSON minimo. El proyecto evita agregar
%% dependencias fuera del stack aprobado (cowboy + recon).

encode(Termino) ->
    iolist_to_binary(enc(Termino)).

enc(null) -> <<"null">>;
enc(undefined) -> <<"null">>;
enc(true) -> <<"true">>;
enc(false) -> <<"false">>;
enc(A) when is_atom(A) -> enc(atom_to_binary(A, utf8));
enc(I) when is_integer(I) -> integer_to_binary(I);
enc(F) when is_float(F) -> float_to_binary(F, [short]);
enc(B) when is_binary(B) -> [$", escapar(B), $"];
enc(L) when is_list(L) -> [$[, unir([enc(X) || X <- L], $,), $]];
enc(M) when is_map(M) ->
    Pares = [[enc(clave(K)), $:, enc(V)] || {K, V} <- maps:to_list(M)],
    [${, unir(Pares, $,), $}];
enc(Otro) ->
    enc(io_lib:format("~p", [Otro])).

clave(K) when is_binary(K) -> K;
clave(K) when is_atom(K) -> atom_to_binary(K, utf8);
clave(K) when is_list(K) -> unicode:characters_to_binary(K);
clave(K) when is_integer(K) -> integer_to_binary(K).

unir([], _Sep) -> [];
unir([Uno], _Sep) -> Uno;
unir([Uno | Resto], Sep) -> [Uno, Sep | unir(Resto, Sep)].

escapar(<<>>) -> [];
escapar(<<$", Resto/binary>>) -> [$\\, $" | escapar(Resto)];
escapar(<<$\\, Resto/binary>>) -> [$\\, $\\ | escapar(Resto)];
escapar(<<$\n, Resto/binary>>) -> [$\\, $n | escapar(Resto)];
escapar(<<$\r, Resto/binary>>) -> [$\\, $r | escapar(Resto)];
escapar(<<$\t, Resto/binary>>) -> [$\\, $t | escapar(Resto)];
escapar(<<C, Resto/binary>>) when C < 32 ->
    [io_lib:format("\\u~4.16.0B", [C]) | escapar(Resto)];
escapar(<<C, Resto/binary>>) -> [C | escapar(Resto)];
escapar(Bin) -> Bin.

decode(Bin) when is_binary(Bin) ->
    try
        {Valor, Resto} = valor(espacios(Bin)),
        case espacios(Resto) of
            <<>> -> {ok, Valor};
            _ -> {error, json_invalido}
        end
    catch
        _Clase:_Razon:_Traza ->
            {error, json_invalido}
    end;
decode(_) ->
    {error, json_invalido}.

espacios(<<C, Resto/binary>>)
  when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    espacios(Resto);
espacios(Bin) ->
    Bin.

valor(<<${, Resto/binary>>) -> objeto(espacios(Resto), #{});
valor(<<$[, Resto/binary>>) -> arreglo(espacios(Resto), []);
valor(<<$", Resto/binary>>) -> cadena(Resto, <<>>);
valor(<<"true", Resto/binary>>) -> {true, Resto};
valor(<<"false", Resto/binary>>) -> {false, Resto};
valor(<<"null", Resto/binary>>) -> {null, Resto};
valor(<<C, _/binary>> = Bin) when C =:= $-; (C >= $0 andalso C =< $9) ->
    numero(Bin);
valor(_) ->
    erlang:error(json_invalido).

objeto(<<$}, Resto/binary>>, Acc) ->
    {Acc, Resto};
objeto(<<$", Resto/binary>>, Acc) ->
    {Clave, R1} = cadena(Resto, <<>>),
    R2 = espacios(R1),
    R3 = case R2 of
             <<$:, R/binary>> -> espacios(R);
             _ -> erlang:error(json_invalido)
         end,
    {Valor, R4} = valor(R3),
    R5 = espacios(R4),
    Nuevo = maps:put(Clave, Valor, Acc),
    case R5 of
        <<$,, R6/binary>> -> objeto(espacios(R6), Nuevo);
        <<$}, R6/binary>> -> {Nuevo, R6};
        _ -> erlang:error(json_invalido)
    end;
objeto(_, _) ->
    erlang:error(json_invalido).

arreglo(<<$], Resto/binary>>, Acc) ->
    {lists:reverse(Acc), Resto};
arreglo(Bin, Acc) ->
    {Valor, R1} = valor(Bin),
    R2 = espacios(R1),
    case R2 of
        <<$,, R3/binary>> -> arreglo(espacios(R3), [Valor | Acc]);
        <<$], R3/binary>> -> {lists:reverse([Valor | Acc]), R3};
        _ -> erlang:error(json_invalido)
    end.

cadena(<<$", Resto/binary>>, Acc) ->
    {Acc, Resto};
cadena(<<$\\, $", Resto/binary>>, Acc) ->
    cadena(Resto, <<Acc/binary, $">>);
cadena(<<$\\, $\\, Resto/binary>>, Acc) ->
    cadena(Resto, <<Acc/binary, $\\>>);
cadena(<<$\\, $/, Resto/binary>>, Acc) ->
    cadena(Resto, <<Acc/binary, $/>>);
cadena(<<$\\, $b, Resto/binary>>, Acc) ->
    cadena(Resto, <<Acc/binary, 8>>);
cadena(<<$\\, $f, Resto/binary>>, Acc) ->
    cadena(Resto, <<Acc/binary, 12>>);
cadena(<<$\\, $n, Resto/binary>>, Acc) ->
    cadena(Resto, <<Acc/binary, $\n>>);
cadena(<<$\\, $r, Resto/binary>>, Acc) ->
    cadena(Resto, <<Acc/binary, $\r>>);
cadena(<<$\\, $t, Resto/binary>>, Acc) ->
    cadena(Resto, <<Acc/binary, $\t>>);
cadena(<<$\\, $u, A, B, C, D, Resto/binary>>, Acc) ->
    Codigo = hex4(A, B, C, D),
    Utf8 = unicode:characters_to_binary([Codigo]),
    cadena(Resto, <<Acc/binary, Utf8/binary>>);
cadena(<<C, Resto/binary>>, Acc) when C >= 32 ->
    cadena(Resto, <<Acc/binary, C>>);
cadena(_, _) ->
    erlang:error(json_invalido).

numero(Bin) ->
    {Digitos, Resto} = tomar_numero(Bin, []),
    Texto = list_to_binary(lists:reverse(Digitos)),
    Valor = case binary:match(Texto, [<<".">>, <<"e">>, <<"E">>]) of
                nomatch -> binary_to_integer(Texto);
                _ -> binary_to_float(Texto)
            end,
    {Valor, Resto}.

tomar_numero(<<C, Resto/binary>>, Acc)
  when (C >= $0 andalso C =< $9); C =:= $-; C =:= $+; C =:= $.; C =:= $e; C =:= $E ->
    tomar_numero(Resto, [C | Acc]);
tomar_numero(Bin, Acc) ->
    {Acc, Bin}.

hex4(A, B, C, D) ->
    (hex(A) bsl 12) bor (hex(B) bsl 8) bor (hex(C) bsl 4) bor hex(D).

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(_) -> erlang:error(json_invalido).
