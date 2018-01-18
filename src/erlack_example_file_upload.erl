-module(erlack_example_file_upload).

-export([start/0, start/1, handle/0]).

start() ->
    start(8000).

start(Port) ->
    erlack_debug_server:start(Port, [], {?MODULE, handle, []}).

handle() ->
    ecgi:apply_handler(
      lists:foldr(
        fun erlack_middleware:wrap/2,
        fun () ->
                handle(get(<<"REQUEST_METHOD">>), get(<<"REQUEST_URI">>))
        end,
        [{erlack_reason_phrase, middleware,[]},
         {erlack_content_length, middleware,[]}])).

handle(<<"GET">>, <<"/">>) ->
    static_response("index.html", <<"text/html; charset=utf-8">>);
handle(<<"GET">>, <<"/upload.js">>) ->
    static_response("upload.js", <<"application/javascript; charset=utf-8">>);
handle(<<"GET">>, <<"/files/", Path/binary>>) ->
    file_response(Path);
handle(<<"PUT">>, <<"/files/", Path/binary>>) ->
    Filename = filename:join([code:priv_dir(?MODULE), "files", Path]),
    touch_file(Filename),

    {ok, File} = file:open(Filename, [read, write, binary]),

    case get(<<"HTTP_CONTENT_RANGE">>) of
        <<"bytes ", ContentRange/binary>> ->
            [Range, Size] = binary:split(ContentRange, <<"/">>),
            _ = binary_to_integer(Size),
            [Start, End] = binary:split(Range, <<"-">>),
            _ = binary_to_integer(End),
            {ok, _} = file:position(File, {bof, binary_to_integer(Start)});
        _ ->
            ok
    end,

    Length = binary_to_integer(get(<<"HTTP_CONTENT_LENGTH">>)),
    receive_file(File, Length),
    { response,
      200,
      #{<<"Content-Type">> => <<"text/plain">>},
      <<"OK\n">>};
handle(_, _) ->
    { response,
      405,
      #{<<"Content-Type">> => <<"text/plain">>},
      <<"405 - Method Not Allowed\n">>}.

not_found() ->
    { response,
      404,
      #{<<"Content-Type">> => <<"text/plain">>},
      <<"404 - Not Found\n">>}.

static_response(Filename, ContentType) ->
    case file:read_file(filename:join(code:priv_dir(?MODULE), Filename)) of
        {error, _} ->
            not_found();
        {ok, Bin} ->
            { response,
              200,
              #{<<"Content-Type">> => ContentType},
              Bin}
    end.

file_response(Filename) ->
    case file:open(filename:join([code:priv_dir(?MODULE), "files", Filename]), [read, binary]) of
        {error, _} ->
            not_found();
        {ok, File} ->
            { response,
              200,
              #{<<"Content-Type">> => <<"application/octet-stream">>},
              {chunked, {fun send_file/1, [File]}}
            }
    end.

send_file(File) ->
    case file:read(File, 4096) of
        eof ->
            ok = ecgi:send(<<>>),
            ok = file:close(File);
        {ok, Bin} ->
            ok = ecgi:send(Bin),
            send_file(File)
    end.

touch_file(Filename) ->
    {ok, File} = file:open(Filename, [append,binary]),
    ok = file:close(File).

receive_file(File, 0) ->
    file:close(File);
receive_file(File, Length) ->
    Size =
        case Length < 4096 of
            true -> Length;
            false -> 4096
        end,
    {ok, Bin} = ecgi:recv(Size),
    ok = file:write(File, Bin),
    receive_file(File, Length - Size).
