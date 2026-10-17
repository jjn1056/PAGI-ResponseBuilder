# NAME

PAGI::ResponseBuilder - Collect a response in stages, for frameworks

# SYNOPSIS

Used directly, in a PAGI application: collect what you know first, choose
the body when you know it, then send the response.

    use Future::AsyncAwait;
    use PAGI::ResponseBuilder;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $res = PAGI::ResponseBuilder->new;

        $res->header('X-Request-Id' => 'req-42');
        $res->cookie(session => 'abc123', httponly => 1);

        if    ($scope->{path} eq '/')      { $res->text("Hello\n") }
        elsif ($scope->{path} eq '/items') { $res->status(201)->json({ id => 7, name => 'ada' }) }
        elsif ($scope->{path} eq '/old')   { $res->redirect('/', 301) }
        else                               { $res->problem({ title => 'Not found', status => 404 }) }

        await $res->to_app->($scope, $receive, $send);
    };

Extended by a framework, which adds its own defaults and shortcuts:

    package My::Response;
    use parent 'PAGI::ResponseBuilder';

    # every response this framework makes says so
    sub new {
        my ($class) = @_;
        my $self = $class->SUPER::new;
        $self->header('X-Powered-By' => 'My::Framework');
        return $self;
    }

    # a shortcut for the framework's handlers: $res->not_found("no item $id")
    sub not_found {
        my ($self, $detail) = @_;
        return $self->problem({ title => 'Not found', status => 404, detail => $detail });
    }

# DESCRIPTION

A framework that handles a request in stages collects the response the same
way: before-hooks, authentication and session code add headers and cookies,
the handler chooses the body, and after-hooks may add more.
PAGI::ResponseBuilder is that collector, for frameworks to extend. Every
response it holds is an ordinary [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse) value made by
["response" in PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse#response).

Applications do not need it: they return a complete value from
`response('Name', ...)`.

The builder holds no scope and never sends. ["to\_app"](#to_app) returns the current
value's application, and sending it is the framework's job.

# STATE AND TRANSITIONS

The builder keeps a collected status, an ordered list of collected headers
(cookies included), a collected Content-Type, and the current value, once a
body method has succeeded. It never keeps a body's input.

- **Body methods** build a new value from the collected state and their
own arguments, and replace the current value only when that succeeds. A
failure leaves the builder exactly as it was. The old value is never asked to
change, so a redirect can replace a redirect, and a Problem a redirect.
- **Setters** (`status`, `header`, `remove_header`, `content_type`,
`cookie`) apply to the current value first, then to the collected state.
A change the value refuses (a status that forbids its body, a redirect's own
status or Location) croaks and changes nothing.
- **A status a body brings with it** (a redirect's, or a `status`
passed to ["as"](#as)) belongs to that value, not to the collected state:
`redirect('/x')` then `text('hi')` is a 200.
- **Cookies are headers.** `cookie` adds a `Set-Cookie` field, so
order, reading and removal follow the header list.
- **Clearing the Content-Type** means the body class's default, whether
it is cleared before or after the body.
- **Reads** come from the current value when there is one, else from
the collected state.

Changing the value ["response"](#response) returns directly is not supported: such
changes are not part of the collected state, and a later body method replaces
the value.

# ERROR TIMING

- **Construction errors** (a status the class forbids or owns,
unencodable JSON, a non-string Text body, a bad redirect target, an unknown
class) are raised by the method that caused them.
- **Delivery errors before the response starts** are raised while the
application from ["to\_app"](#to_app) runs, before it sends `http.response.start`: a
File's existence, readability and range planning. Nothing has been sent, so a
framework may catch them and send another response.
- **Failures after the response has started** cannot be answered with
another response; rethrow them. A Stream sends its start before it calls its
producer, so a producer's failure is always one of these.
`pagi.connection`'s `response_started` tells the two cases apart.

# CONSTRUCTOR

## new

    my $builder = PAGI::ResponseBuilder->new;

Takes no arguments. A subclass built with Moo passes none from
`FOREIGNBUILDARGS`. Builder state lives under the `_response_builder` key of
the blessed hash.

# COLLECTING

Each setter returns the builder.

## status

    $builder->status(201);
    my $code = $builder->status;

Sets the status, or reads it: the current value's status, else the collected
status, else 200. An invalid status croaks when it is set.

## status\_try

Sets the status unless ["has\_status"](#has_status).

## has\_status

True when a status was collected, or the current value has one (a Redirect
or Problem does).

## header

    $builder->header('X-Example' => 'one');
    my $value = $builder->header('X-Example');

Adds a header field, or reads one as a response value's `header` does (["metadata" in PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse#metadata)). The
value must be a defined string, for every field. A `Content-Type` name with
a defined value means ["content\_type"](#content_type); clear the type with
`content_type(undef)` or ["remove\_header"](#remove_header).

## header\_all

Every value of a field, as an arrayref.

## headers

    my $fields = $builder->headers;    # a PAGI::Headers

A copy of the header fields as they stand, as a [PAGI::Headers](https://metacpan.org/pod/PAGI%3A%3AHeaders): the current
value's own once a body is chosen, Content-Type included; before that, the
collected fields, cookies included, with a collected Content-Type last. It is
a copy: changing it does not change the builder.

## has\_header

True when the field is present: on the current value if there is one, else
in the collected headers.

## header\_try

Adds the field unless it is present.

## remove\_header

Removes every value of a field. A `Content-Type` name means
`content_type(undef)`.

## content\_type

    $builder->content_type('text/csv');
    $builder->content_type(undef);

Sets, clears or reads the Content-Type. Clearing means the body class's
default. The body class may adjust the type: Text and HTML add
`; charset=utf-8` to one without a charset, except JSON types (see
[PAGI::Response::Text](https://metacpan.org/pod/PAGI%3A%3AResponse%3A%3AText)).

## content\_type\_try

Sets the Content-Type unless one is present. After a body, the class's
default counts as present, so `text('x')->content_type_try('text/csv')`
keeps `text/plain; charset=utf-8`.

## has\_content\_type

True when a Content-Type is present: on the current value if there is one,
else collected.

## cookie

    $builder->cookie(session => $id, httponly => 1, samesite => 'Lax');

Adds a `Set-Cookie` field, formatted as a response value's `cookie`
formats one. The options:

- `path`: defaults to `/`.
- `domain`, `expires` and `samesite`: sent as given, when defined.
- `max_age`: sent as `Max-Age`, when defined.
- `secure` and `httponly`: flags, sent when true.

## delete\_cookie

    $builder->delete_cookie('session', path => '/app');

Adds a `Set-Cookie` field that expires the cookie: ["cookie"](#cookie) with an empty
value, `max_age` 0 and `expires` 0. It takes ["cookie"](#cookie)'s options, so a
`path` or `domain` can match the cookie it expires.

# CHOOSING THE BODY

Each method builds the value now and returns the builder.

## as

    $builder->as('JSON', $data);
    $builder->as('+My::Response', $value);
    $builder->as('File', $path, filename => 'report.pdf');
    $builder->as('Redirect', '/moved', status => 301);
    $builder->as('Empty');

Builds `response($name, @arguments, ...)`: the arguments go to the class
unchanged, followed by the collected status, headers and Content-Type. So any
response class works, whatever its constructor takes, and its own rules apply
(Empty, for example, refuses a collected Content-Type). `$name` resolves as
in ["response" in PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse#response).

The arguments are read as the response classes read theirs: positional
values, then name/value pairs. A `status` among the pairs belongs to this
body: it replaces the collected status for it and is not collected, as with
["redirect"](#redirect). `headers` and `content_type` croak, since the builder owns
them.

## text

    $builder->text($string);
    $builder->text($string, status => 404);

`as('Text', $string, ...)`. The string must be defined and not a reference;
a framework that renders other values stringifies them first, in its own
override. A trailing `status` belongs to this body, as with ["as"](#as); headers
and the Content-Type are the builder's, and croak here.

## html

    $builder->html($string);
    $builder->html($string, status => 404);

`as('HTML', $string, ...)`, with the same rules as ["text"](#text).

## json

    $builder->json($data);
    $builder->json($data, status => 422);

`as('JSON', $data, ...)`, taking a trailing `status` as ["text"](#text) does. Data
that cannot be encoded dies here.

## bytes

    $builder->bytes($encoded);
    $builder->content_type('image/png')->bytes($png, status => 201);

`as('+PAGI::Response', $encoded, ...)`: a body of bytes already encoded,
sent as they are, with `application/octet-stream` unless a Content-Type is
collected. Characters croak; encode them first. It takes a trailing `status`
as ["text"](#text) does.

## problem

    $builder->problem({ type => '/problems/out-of-stock', title => 'Out of stock', status => 409 });

`as('Problem', ...)`: an RFC 9457 problem details response, its arguments
those of [PAGI::Response::Problem](https://metacpan.org/pod/PAGI%3A%3AResponse%3A%3AProblem).

## redirect

    $builder->redirect('/login');
    $builder->redirect('/moved', 301);

`as('Redirect', $url, status =` $status)>, the status defaulting to 302. It
belongs to the value rather than the collected state.

## file

    $builder->file($path, filename => 'report.pdf');

`as('File', $path, @options)`. The file is checked when the response is
sent, not here (see ["ERROR TIMING"](#error-timing)).

## stream

    $builder->stream(async sub { my ($writer) = @_; await $writer->write($chunk) });

`as('Stream', $producer, @options)`. The producer runs after the response
has started.

## empty

An Empty response with the collected status, or 200, and no Content-Type.
This is the builder's own empty response, not `as('Empty')`: it leaves a
collected Content-Type out instead of passing it to Empty, which refuses one.

## has\_body\_source

True once a body method has succeeded.

# FINISHING

## response

The current value. With no body chosen, a new Empty value (as ["empty"](#empty)
builds) each time it is called.

## to\_app

    await $builder->to_app->($scope, $receive, $send);

The current value's application.

# COOKBOOK

Each recipe starts from a fresh builder, `my $res = PAGI::ResponseBuilder->new`,
and leaves in it the response a framework would send with `$res->to_app`.
Collecting and choosing chain: every method returns the builder.

## Text with a status

    $res->status(201)->text("Created\n");

## JSON, with a header and a cookie collected first

A before-hook and the session code add to the response; the handler picks the
body last, and keeps what they added.

    $res->header('X-Request-Id' => 'req-42');
    $res->cookie(session => 'abc123', httponly => 1, samesite => 'Lax');
    $res->json({ id => 7, name => 'ada' });

## HTML

    $res->html('<p>Hello, <b>world</b></p>');

## A redirect after a form post, keeping a cookie

    $res->cookie(flash => 'saved')->redirect('/items/7', 303);

## No content

    $res->status(204)->empty;

## A Problem details error

    $res->problem({
        type   => '/problems/out-of-stock',
        title  => 'Out of stock',
        status => 409,
    });

## A file download

The file is read when the response is sent, not when it is chosen.

    $res->file('reports/2026-10.csv', filename => 'october.csv');

## A streamed body

    $res->content_type('text/csv')->stream(async sub {
        my ($writer) = @_;
        await $writer->write("id,name\n");
        await $writer->write("7,ada\n");
    });

## Text in a charset other than UTF-8

Text and HTML always send UTF-8. For another charset, encode the text and
send the bytes.

    use Encode qw(encode);

    $res->content_type('text/plain; charset=iso-8859-1')
        ->bytes(encode('iso-8859-1', "caf\x{e9}"));

## Replacing the body when the handler fails

A body method replaces the body chosen before it, and the headers and cookies
collected so far are kept, so an error handler can answer in place of a
response the handler already chose.

    $res->header('X-Request-Id' => 'req-42')->json({ ok => 1 });

    # ... the handler then dies, and the framework's error handler answers:
    $res->status(500)->text('Internal Server Error');

## A response class of your own

["as"](#as) builds any response class, so a class written for one application is
chosen the same way as Tools' own.

    $res->as('+My::Response::CSV', [ [qw(id name)], [7, 'ada'] ]);

# SUBCLASSING

Frameworks extend this class. A subclass may rely on the following.

- Builder state lives under the `_response_builder` key of the
blessed hash, so a subclass's own keys, including Moo and Mooish attributes,
do not collide with it. There is no `BUILD` or `DEMOLISH` logic, and the
builder holds no scope, connection or sender.
- ["new"](#new) takes no arguments; a Moo subclass's `FOREIGNBUILDARGS`
returns an empty list.
- Every public method is an ordinary method that a subclass may
override and call with `SUPER::`. Coercing input before the builder sees it
(a framework that renders exception objects stringifies them in its `text`)
is the intended pattern.
- Some methods call others through `$self`, so an override sees those
calls too:

    - `text`, `html`, `json`, `bytes`, `problem`, `file`, `stream` and `redirect` call
    ["as"](#as). `empty` builds the builder's own empty response and does not.
    - `cookie` and `header_try` call ["header"](#header); `delete_cookie` calls
    ["cookie"](#cookie).
    - `status_try`, `header_try` and `content_type_try` ask
    ["has\_status"](#has_status), ["has\_header"](#has_header) and ["has\_content\_type"](#has_content_type) first;
    `has_content_type` calls ["has\_header"](#has_header).
    - `header` and `remove_header` with a `Content-Type` name, and
    `content_type_try`, call ["content\_type"](#content_type); `status_try` calls ["status"](#status).
    - `to_app` calls ["response"](#response).

    An override of ["as"](#as) must not call back into the shorthands (`text` and
    the others): they call `as`, so the two would recurse.

- Errors the builder and the response classes raise with [Carp](https://metacpan.org/pod/Carp)
name the line that called the builder, or that called a subclass's method:
the builder is internal to Carp, and Carp trusts a subclass through its
`@ISA`. A subclass that sets `@CARP_NOT` replaces that trust, so it lists
`PAGI::ResponseBuilder` there too. Errors a response class raises with
`die` name the class's own line: a Text or HTML body that is not a defined
string, and JSON data that cannot be encoded.

# SEE ALSO

[PAGI::Tools](https://metacpan.org/pod/PAGI%3A%3ATools), [PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse), ["response" in PAGI::Response](https://metacpan.org/pod/PAGI%3A%3AResponse#response)

# AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

# LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as the Artistic License 2.0.
