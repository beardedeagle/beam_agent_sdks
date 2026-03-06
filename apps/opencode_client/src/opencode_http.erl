-module(opencode_http).

-moduledoc """
Pure HTTP request/response helpers for OpenCode client.

No processes. All functions are pure transformations used by
opencode_session to build gun HTTP requests. Handles URL parsing,
path construction, authentication, and header generation.
""".

-export([
    parse_base_url/1,
    build_path/2,
    auth_headers/1,
    common_headers/2,
    encode_basic_auth/2
]).

-dialyzer({no_underspecs, [auth_headers/1, split_scheme/1]}).

%%====================================================================
%% Public API
%%====================================================================

-doc """
Parse a base URL into `{Host, Port, BasePath}` tuple.

Handles `http://` and `https://` schemes, extracting the host,
port (with scheme defaults of 80/443), and any path prefix.

Examples:

```
"http://localhost:4096"      -> {<<"localhost">>, 4096, <<>>}
"http://localhost:4096/api"  -> {<<"localhost">>, 4096, <<"/api">>}
"https://api.example.com"   -> {<<"api.example.com">>, 443, <<>>}
```
""".
-spec parse_base_url(binary() | string()) ->
    {binary(), inet:port_number(), binary()}.
parse_base_url(Url) when is_list(Url) ->
    parse_base_url(list_to_binary(Url));
parse_base_url(Url) when is_binary(Url) ->
    {Scheme, Rest0} = split_scheme(Url),
    DefaultPort = case Scheme of
        <<"https">> -> 443;
        _           -> 80
    end,
    %% Split host[:port] from path
    {HostPort, Path} = split_host_path(Rest0),
    {Host, Port} = split_host_port(HostPort, DefaultPort),
    BasePath = case Path of
        <<>> -> <<>>;
        <<"/">> -> <<>>;
        P -> strip_trailing_slash(P)
    end,
    {Host, Port, BasePath}.

-doc """
Join a base path with an endpoint path (and optional segments).

Concatenates all segments into a single iolist and converts to
binary. No URL encoding is performed.
""".
-spec build_path(binary(), iodata()) -> binary().
build_path(BasePath, Endpoint) ->
    iolist_to_binary([BasePath, Endpoint]).

-doc "Build authorization headers for the given auth config.".
-spec auth_headers(none | {basic, binary()}) -> [{binary(), binary()}].
auth_headers(none) ->
    [];
auth_headers({basic, Encoded}) ->
    [{<<"authorization">>, <<"Basic ", Encoded/binary>>}].

-doc """
Build common request headers (content-type, accept, x-opencode-directory,
and any auth headers).
""".
-spec common_headers(none | {basic, binary()}, binary()) ->
    [{binary(), binary()}].
common_headers(Auth, Dir) ->
    [
        {<<"content-type">>,       <<"application/json">>},
        {<<"accept">>,             <<"application/json">>},
        {<<"x-opencode-directory">>, Dir}
        | auth_headers(Auth)
    ].

-doc "Base64-encode `\"user:pass\"` for HTTP Basic auth.".
-spec encode_basic_auth(binary(), binary()) -> {basic, binary()}.
encode_basic_auth(User, Pass) ->
    {basic, base64:encode(<<User/binary, ":", Pass/binary>>)}.

%%====================================================================
%% Internal helpers
%%====================================================================

-spec split_scheme(binary()) -> {binary(), binary()}.
split_scheme(<<"https://", Rest/binary>>) -> {<<"https">>, Rest};
split_scheme(<<"http://", Rest/binary>>)  -> {<<"http">>, Rest};
split_scheme(Rest)                         -> {<<"http">>, Rest}.

-spec split_host_path(binary()) -> {binary(), binary()}.
split_host_path(HostAndPath) ->
    case binary:split(HostAndPath, <<"/">>) of
        [HostPort]        -> {HostPort, <<>>};
        [HostPort | Parts] ->
            Path = iolist_to_binary([<<"/">> | lists:join(<<"/">>, Parts)]),
            {HostPort, Path}
    end.

-spec split_host_port(binary(), inet:port_number()) ->
    {binary(), inet:port_number()}.
split_host_port(HostPort, DefaultPort) ->
    case binary:split(HostPort, <<":">>) of
        [Host]          -> {Host, DefaultPort};
        [Host, PortBin] ->
            Port = try binary_to_integer(PortBin)
                   catch _:_ -> DefaultPort
                   end,
            {Host, Port}
    end.

-spec strip_trailing_slash(binary()) -> binary().
strip_trailing_slash(<<>>) -> <<>>;
strip_trailing_slash(B) ->
    case binary:last(B) of
        $/ -> binary:part(B, 0, byte_size(B) - 1);
        _  -> B
    end.
