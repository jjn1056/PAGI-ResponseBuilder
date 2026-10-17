#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';

use PAGI::ResponseBuilder;
use PAGI::Test::Client;

# An exact class for as('+...'); response() accepts it once loaded.
BEGIN {
    package My::Test::Response;
    our @ISA = ('PAGI::Response::Text');
    require PAGI::Response::Text;
    $INC{'My/Test/Response.pm'} = __FILE__;
}

# A subclass with a key of its own named like old builder state.
BEGIN {
    package My::Framework::Response;
    our @ISA = ('PAGI::ResponseBuilder');
    sub new { my $self = PAGI::ResponseBuilder::new(shift); $self->{_status} = 'mine'; $self }
}

sub builder { PAGI::ResponseBuilder->new }
sub sent    { PAGI::Test::Client->new(app => $_[0]->to_app)->get('/') }

subtest 'new takes no arguments' => sub {
    isa_ok builder(), 'PAGI::ResponseBuilder';
    like dies { PAGI::ResponseBuilder->new(status => 200) }, qr/takes no arguments/;
};

subtest 'state collected before text reaches the value' => sub {
    my $res = sent(builder()->status(201)->header('X-One' => 'a')
        ->cookie(session => 'abc')->text("caf\x{e9}"));
    is $res->status, 201, 'status';
    is $res->header('x-one'), 'a', 'header';
    is $res->header('set-cookie'), 'session=abc; path=/', 'cookie';
    is $res->content_type, 'text/plain; charset=utf-8', "Text's default type";
    is $res->text, "caf\x{e9}", 'body';
};

subtest 'a header and a cookie after json are sent, and a later body keeps them' => sub {
    my $b = builder()->json({ok => 1})->header('X-After' => 'yes')->cookie(late => 1);
    my $res = sent($b);
    is $res->header('x-after'), 'yes';
    is $res->header('set-cookie'), 'late=1; path=/';
    $res = sent($b->text('replaced'));
    is $res->text, 'replaced', 'the new body';
    is $res->header('x-after'), 'yes', 'header kept across the new body';
    is $res->header('set-cookie'), 'late=1; path=/', 'cookie kept across the new body';
};

subtest 'a refused status leaves the builder unchanged' => sub {
    my $b = builder()->status(201)->text('a');
    like dies { $b->status(204) }, qr/response body is forbidden for status 204/;
    is $b->status, 201, 'status unchanged';
    is sent($b)->status, 201, 'value unchanged';
    my $r = builder()->redirect('/x');
    like dies { $r->status(301) }, qr/Redirect status is response-owned/;
    is $r->status, 302, "the Redirect keeps its own status";
};

subtest 'redirecting twice' => sub {
    my $res = sent(builder()->redirect('/a', 301)->redirect('/b', 302));
    is $res->status, 302;
    is $res->location, '/b';
};

subtest 'a Problem and a redirect replace each other' => sub {
    my $b = builder()->as('Problem', { title => 'Bad', status => 400 });
    is sent($b->redirect('/next'))->status, 302, 'Problem replaced by a redirect';
    is sent($b->as('Problem', { title => 'Bad', status => 400 }))->status, 400,
        'redirect replaced by a Problem';
};

subtest "a redirect's status does not stick" => sub {
    is sent(builder()->redirect('/x')->text('hi'))->status, 200, 'redirect then text';
    is sent(builder()->as('Redirect', '/x')->text('hi'))->status, 200, "as('Redirect') then text";
};

subtest 'a collected status reaches as() but not redirect()' => sub {
    is sent(builder()->status_try(200)->redirect('/x'))->status, 302, 'redirect passes its own';
    my $b = builder()->status_try(200)->text('kept');
    like dies { $b->as('Redirect', '/x') }, qr/Redirect status must be one of/;
    is sent($b)->text, 'kept', 'the builder is unchanged after the failure';
};

subtest 'a failed body leaves the builder untouched' => sub {
    my $b = builder()->status(201)->text('a');
    like dies { $b->json({ x => sub { 1 } }) }, qr/JSON can only represent/;
    my $res = sent($b);
    is $res->status, 201;
    is $res->text, 'a';
};

subtest 'removed cookies stay removed' => sub {
    my $b = builder()->cookie(session => 'old')->text('first');
    $b->remove_header('Set-Cookie');
    is sent($b->json({ok => 1}))->header_all('set-cookie'), [], 'not replayed by the rebuild';
};

subtest 'removal is case-insensitive' => sub {
    my $b = builder()->cookie(a => 1);
    $b->remove_header('set-cookie');
    is sent($b->text('x'))->header_all('set-cookie'), [];
};

subtest 'header order is call order' => sub {
    my $res = sent(builder()->cookie(a => 1)->header('Set-Cookie' => 'raw=2')
        ->cookie(b => 3)->text('x'));
    is $res->header_all('set-cookie'), ['a=1; path=/', 'raw=2', 'b=3; path=/'];
};

subtest 'clearing the type gives the class default, before or after the body' => sub {
    is sent(builder()->content_type('text/csv')->content_type(undef)->text('x'))->content_type,
        'text/plain; charset=utf-8', 'cleared before text';
    is sent(builder()->content_type('text/csv')->text('x')->content_type(undef))->content_type,
        'text/plain; charset=utf-8', 'cleared after text';
    # File has no default; it chooses application/octet-stream itself when sent
    is builder()->file(__FILE__)->content_type('text/x-perl')->content_type(undef)
        ->content_type, undef, 'File has no default';
    is sent(builder()->text('x')->remove_header('Content-Type'))->content_type,
        'text/plain; charset=utf-8', 'remove_header(Content-Type) is content_type(undef)';
};

subtest 'charset rule' => sub {
    is sent(builder()->header('Content-Type' => 'text/csv')->text('a,b'))->content_type,
        'text/csv; charset=utf-8', 'header(Content-Type) is content_type';
    is sent(builder()->header('content-type' => 'text/csv')->text('a,b'))->content_type,
        'text/csv; charset=utf-8', 'in lower case too';
    is sent(builder()->content_type('application/json')->text('{}'))->content_type,
        'application/json', 'JSON gets no charset';
    is sent(builder()->content_type('application/vnd.api+json')->text('{}'))->content_type,
        'application/vnd.api+json', '+json gets no charset';
    is sent(builder()->content_type('text/csv; charset=latin1')->text('a'))->content_type,
        'text/csv; charset=latin1', 'a named charset is kept';
    is sent(builder()->text('x')->content_type('text/csv'))->content_type,
        'text/csv; charset=utf-8', 'set after the body';
    is sent(builder()->content_type('application/xml')->json({}))->content_type,
        'application/xml', 'not applied to JSON bodies';
};

subtest 'empty means 200' => sub {
    my $res = sent(builder()->content_type('text/plain')->empty);
    is $res->status, 200;
    is $res->content_type, undef, 'no Content-Type';
    is sent(builder()->status(204)->empty)->status, 204, 'a collected status is used';
};

subtest 'response with no body' => sub {
    my $b = builder()->header('X-Only' => 'yes');
    my ($one, $two) = ($b->response, $b->response);
    isa_ok $one, 'PAGI::Response::Empty';
    ok $one != $two, 'a new value each call';
    ok !$b->has_body_source, 'still no body';
    is $one->status, 200;
    is $one->header('X-Only'), 'yes';
};

subtest 'redirect status and content type' => sub {
    is sent(builder()->redirect('/login'))->status, 302;
    is sent(builder()->redirect('/x', 301))->status, 301;
    is sent(builder()->content_type('text/x-r')->redirect('/to'))->content_type, 'text/x-r',
        'a collected type is passed through unchanged';
};

subtest 'as() resolves names like response()' => sub {
    isa_ok builder()->as('+My::Test::Response', 'x')->response, 'My::Test::Response';
    like dies { builder()->as('Nope', 1) }, qr/response\('Nope'\): cannot load/;
};

subtest 'as() refuses headers and content_type, which the builder owns' => sub {
    for my $name (qw(headers content_type)) {
        like dies { builder()->as('JSON', {}, $name => 1) }, qr/as\(\) takes no '$name' option/;
    }
};

subtest 'as() passes its arguments through, for any constructor shape' => sub {
    is sent(builder()->as('Empty'))->status, 204, "Empty takes no value; the class's own default";
    like dies { builder()->content_type('text/plain')->as('Empty') },
        qr/Empty response does not permit Content-Type/, "the class's own rules apply";
    is sent(builder()->status(201)->as('Text', 'status'))->text, 'status',
        'a value that reads "status" is a value, not an option';
    is sent(builder()->status(201)->as('Text', 'status'))->status, 201,
        'and the collected status still applies';
};

subtest 'a status passed to as() belongs to that body' => sub {
    my $b = builder()->as('Redirect', '/x', status => 301);
    is sent($b)->status, 301, 'the body has it';
    is sent($b->text('next'))->status, 200, 'it was not collected';
    is sent(builder()->as('Empty', status => 202))->status, 202, 'any class';
    is sent(builder()->status(500)->as('Problem', { title => 'Bad', status => 400 }, status => 400))
        ->status, 400, 'it replaces a collected status that would disagree';
    is sent(builder()->as('JSON', {}, status => 201))->status, 201, 'JSON too';
};

subtest 'file options pass through; a missing file fails when sent' => sub {
    my $res = sent(builder()->file(__FILE__, filename => 'r.pl'));
    like $res->header('content-disposition'), qr/r\.pl/, 'filename option reached File';
    my $app = builder()->file('/no/such/file')->to_app;
    my @events;
    my $f = $app->(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        sub { Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; Future->done },
    );
    like dies { $f->get }, qr/Cannot inspect selected file/, 'fails while sending';
    is \@events, [], 'before http.response.start';
};

subtest 'text and html are strict' => sub {
    like dies { builder()->text(undef) }, qr/defined Unicode scalar/;
    like dies { builder()->text(bless {}, 'Some::Object') }, qr/defined Unicode scalar/;
    like dies { builder()->text('a', 'b') }, qr/response options must be name\/value pairs/,
        'a trailing value that is not a name/value pair';
    like dies { builder()->text }, qr/text\(\) takes a body and an optional status/;
};

subtest 'refused setters change nothing' => sub {
    my $r = builder()->redirect('/x');
    like dies { $r->header('Location' => '/y') }, qr/Redirect Location is response-owned/;
    is sent($r)->location, '/x';
    my $b = builder();
    like dies { $b->header('X' => undef) }, qr/Header value is required/;
    ok !$b->has_header('X'), 'nothing collected';
    like dies { $b->content_type('text/csv')->header('Content-Type' => undef) },
        qr/Header value is required/, 'Content-Type too: clearing is content_type(undef)';
    is $b->content_type, 'text/csv', 'the collected type is unchanged';
    like dies { $b->status('abc') }, qr/Status must be a number between 100-599/;
    ok !$b->has_status, 'no status collected';
};

subtest 'reads come from the value once there is one' => sub {
    my $b = builder()->header('X-A' => 1);
    is $b->header('X-A'), 1, 'collected';
    $b->file(__FILE__);
    is $b->header('X-A'), 1, 'collected header is on the value';
    is $b->status, 200, 'status from the value';
    ok !$b->has_status, 'Text/File carry no explicit status';
    ok $b->has_body_source;
};

subtest 'stream' => sub {
    my $res = sent(builder()->stream(sub {
        my ($writer) = @_;
        return $writer->write("one\n")->then(sub { $writer->write("two\n") });
    }));
    is $res->text, "one\ntwo\n";
};

subtest 'delete_cookie' => sub {
    like sent(builder()->delete_cookie('session')->text('x'))->header('set-cookie'),
        qr/\Asession=; .*max-age=0/i;
};

subtest "cookies are formatted as PAGI::Response's own" => sub {
    my %options = (path => '/app', domain => 'example.com', expires => 1767225600,
        max_age => 3600, secure => 1, httponly => 1, samesite => 'Strict');
    my $tools = PAGI::Test::Client->new(
        app => PAGI::Response::response('Text', 'x')->cookie(session => 'abc', %options)->to_app)->get('/');
    my $mine = sent(builder()->cookie(session => 'abc', %options)->text('x'));
    is $mine->header('set-cookie'), $tools->header('set-cookie'), 'every option';
    is sent(builder()->cookie(a => 1)->text('x'))->header('set-cookie'),
        PAGI::Test::Client->new(app => PAGI::Response::response('Text', 'x')->cookie(a => 1)->to_app)
            ->get('/')->header('set-cookie'),
        'no options';
    is sent(builder()->delete_cookie(session => path => '/app')->text('x'))->header('set-cookie'),
        PAGI::Test::Client->new(
            app => PAGI::Response::response('Text', 'x')->delete_cookie(session => path => '/app')->to_app)
            ->get('/')->header('set-cookie'),
        'delete_cookie';
};

subtest "a status is refused exactly when a response value's setter refuses it" => sub {
    for my $code (undef, '', 'abc', 99, 100, 200, '0200', 599, 600, '200x', ' 200', 2.5, []) {
        my $label = defined $code ? (ref $code ? 'a reference' : "'$code'") : 'undef';
        my $tools = dies { PAGI::Response::response('Empty')->status($code) };
        my $mine  = dies { builder()->status($code) };
        is defined $mine, defined $tools, "$label: refused alike";
        is $mine =~ s/ at .*//sr, $tools =~ s/ at .*//sr, "$label: same message"
            if defined $tools;
    }
};

subtest "errors raised through a subclass's method name its caller's line" => sub {
    eval q{
#line 1 "My/Plain/Response.pm"
        package My::Plain::Response;
        our @ISA = ('PAGI::ResponseBuilder');
        sub text { my ($self, @args) = @_; return $self->SUPER::text(@args) }
        1;
    } or die $@;
    my $file = quotemeta __FILE__;
    like dies { My::Plain::Response->new->status(204)->text('x') },
        qr/forbidden for status 204 at $file line/, 'not the subclass file';

    # @CARP_NOT replaces the trust @ISA gives, so it must list the builder.
    for my $listed (0, 1) {
        my $class = $listed ? 'My::Listing::Response' : 'My::Unlisted::Response';
        my $list = join ', ', map {"'$_'"} 'Some::Other', ($listed ? 'PAGI::ResponseBuilder' : ());
        eval qq{
#line 1 "$class.pm"
            package $class;
            our \@ISA = ('PAGI::ResponseBuilder');
            our \@CARP_NOT = ($list);
            sub text { my (\$self, \@args) = \@_; return \$self->SUPER::text(\@args) }
            1;
        } or die $@;
    }
    like dies { My::Unlisted::Response->new->status(204)->text('x') },
        qr/at My::Unlisted::Response\.pm line/, '@CARP_NOT without the builder: the subclass line';
    like dies { My::Listing::Response->new->status(204)->text('x') },
        qr/at $file line/, "\@CARP_NOT listing the builder: the caller's line";
};

subtest 'subclass keys do not collide' => sub {
    my $b = My::Framework::Response->new;
    $b->status(201)->text('x');
    is $b->{_status}, 'mine', "the subclass's key is untouched";
    is sent($b)->status, 201;
};

subtest "errors name the caller's file, not the builder's" => sub {
    my $file = quotemeta __FILE__;
    like dies { builder()->status(204)->text('x') },
        qr/forbidden for status 204 at $file line/, 'a body-time error';
    like dies { builder()->text('x')->status(204) },
        qr/forbidden for status 204 at $file line/, 'a setter refused by the value';
    like dies { builder()->redirect('/x')->header(Location => '/y') },
        qr/response-owned at $file line/, "a redirect's own header";
    like dies { builder()->status('abc') },
        qr/100-599 at $file line/, "the builder's own check";
};

# Pins the delegation documented under SUBCLASSING.
BEGIN {
    package My::Recording::Response;
    our @ISA = ('PAGI::ResponseBuilder');
    our @calls;
    sub as     { my $self = shift; push @calls, "as:$_[0]"; $self->SUPER::as(@_) }
    sub header { my $self = shift; push @calls, "header:$_[0]" if @_ > 1; $self->SUPER::header(@_) }
}

subtest 'documented delegation between methods' => sub {
    @My::Recording::Response::calls = ();
    my $b = My::Recording::Response->new;
    $b->text('a')->html('b')->json({})->file(__FILE__)->stream(sub { Future->done });
    $b->problem({ title => 'x', status => 400 });
    $b->bytes('raw');
    $b->redirect('/x')->empty;
    $b->cookie(a => 1)->delete_cookie('b')->header_try('X-T' => 1);
    is \@My::Recording::Response::calls,
        [qw(as:Text as:HTML as:JSON as:File as:Stream as:Problem as:+PAGI::Response as:Redirect
            header:Set-Cookie header:Set-Cookie header:X-T)],
        'body methods call as() except empty(); cookies and header_try call header()';
};

# Records each call a method makes through $self, for the delegation
# documented under SUBCLASSING.
BEGIN {
    package My::Tracing::Response;
    our @ISA = ('PAGI::ResponseBuilder');
    our @calls;
    for my $method (qw(status has_status header has_header content_type
                       has_content_type cookie)) {
        no strict 'refs';
        *{$method} = sub { push @calls, $method; my $super = "PAGI::ResponseBuilder::$method"; shift->$super(@_) };
    }
}

subtest 'documented delegation of the _try, has_ and cookie methods' => sub {
    my %expected = (
        status_try       => [qw(has_status status)],
        header_try       => [qw(has_header header)],
        content_type_try => [qw(has_content_type has_header content_type)],
        delete_cookie    => [qw(cookie header)],
    );
    my %arguments = (status_try => [201], header_try => ['X-T' => 1],
        content_type_try => ['text/csv'], delete_cookie => ['b']);
    for my $method (sort keys %expected) {
        @My::Tracing::Response::calls = ();
        My::Tracing::Response->new->$method(@{ $arguments{$method} });
        is \@My::Tracing::Response::calls, $expected{$method}, $method;
    }
};

subtest 'headers is a copy of the header fields as they stand' => sub {
    my $b = builder()->header('X-A' => 1)->cookie(s => 1)->content_type('text/csv');
    my $before = $b->headers;
    isa_ok $before, 'PAGI::Headers';
    is [ map { [@$_] } @$before ],
        [['X-A', 1], ['Set-Cookie', 's=1; path=/'], ['Content-Type', 'text/csv']],
        'before a body: the collected fields, Content-Type last';

    $b->text('x');
    is [ map { [@$_] } @{ $b->headers } ], [ map { [@$_] } @{ $b->response->headers } ],
        "after a body: the value's own fields";

    $b->headers->add('X-Copy' => 1);
    ok !$b->has_header('X-Copy'), 'changing the copy leaves the builder alone';
};

subtest 'text, html and json take a trailing status' => sub {
    is sent(builder()->text('gone', status => 410))->status, 410, 'text';
    is sent(builder()->html('<p>gone</p>', status => 410))->status, 410, 'html';
    is sent(builder()->json({ gone => 1 }, status => 410))->status, 410, 'json';

    my $b = builder()->text('gone', status => 410);
    is sent($b->json({}))->status, 200, 'the status belongs to that body, as with as()';

    like dies { builder()->text('x', headers => ['X-A' => 1]) },
        qr/takes no 'headers' option: set it on the builder/, 'headers are still the builder\'s';
    like dies { builder()->json({}, content_type => 'text/plain') },
        qr/takes no 'content_type' option/, 'and so is the Content-Type';
};

subtest 'problem is as(Problem)' => sub {
    my $res = sent(builder()->header('X-A' => 1)
        ->problem({ title => 'Out of stock', status => 409 }));
    is $res->status, 409;
    is $res->header('content-type'), 'application/problem+json';
    is $res->json->{title}, 'Out of stock';
    is $res->header('x-a'), 1, 'collected headers are kept';
};

subtest 'bytes sends encoded bytes as they are' => sub {
    my $res = sent(builder()->bytes("\x00\x01\xFF"));
    is $res->header('content-type'), 'application/octet-stream', 'the plain response type by default';
    is $res->content, "\x00\x01\xFF";

    $res = sent(builder()->content_type('text/plain; charset=iso-8859-1')
        ->bytes("caf\xE9", status => 201));
    is $res->header('content-type'), 'text/plain; charset=iso-8859-1', 'a collected Content-Type is kept';
    is $res->status, 201, 'and a trailing status taken';

    like dies { builder()->bytes("wide \x{263a}") }, qr/encoded bytes/,
        'characters are refused: encode them first';
};

done_testing;
