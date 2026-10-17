#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin;

use PAGI::Test::Client;

# The SYNOPSIS runs exactly as published: its indented verbatim paragraphs,
# joined in order, must build $app, which every path of its handler drives.

my $pod = do {
    open my $fh, '<', "$FindBin::Bin/../lib/PAGI/ResponseBuilder.pm" or die $!;
    local $/;
    <$fh>;
};
my ($section) = $pod =~ /^=head1 SYNOPSIS\n(.*?)^=head1 /ms or die 'no SYNOPSIS';
my $code = join "\n",
    map  { s/^    //mgr }
    grep { /\A[ \t]/ } split /\n{2,}/, $section =~ s/\A\n+//r;

my $app = eval "$code;\n\$app";
is $@, '', 'the SYNOPSIS compiles and runs as published' or done_testing, exit;
ok ref $app eq 'CODE', 'and builds $app';

my $client = PAGI::Test::Client->new(app => $app);

sub hooks_ran {
    my ($res, $label) = @_;
    is $res->header('x-request-id'), 'req-42', "$label: the before-hook header is sent";
    like $res->header('set-cookie'), qr/\Asession=abc123;/, "$label: and the session cookie";
    is $res->header('x-handled-by'), 'My::Framework', "$label: and the after-hook header";
}

my $res = $client->get('/');
is [$res->status, $res->content], [200, "Hello\n"], '/ is text';
hooks_ran($res, '/');

$res = $client->post('/items');
is $res->status, 201, '/items is a 201';
is $res->json, { id => 7, name => 'ada' }, 'with a JSON body';
hooks_ran($res, '/items');

$res = $client->get('/about');
is $res->header('content-type'), 'text/html; charset=utf-8', '/about is HTML';
is $res->content, '<h1>About</h1>';

$res = $client->get('/old');
is [$res->status, $res->header('location')], [301, '/about'], '/old redirects';
hooks_ran($res, '/old');

$res = $client->get('/missing');
is $res->status, 404, '/missing is a 404';
is $res->header('content-type'), 'application/problem+json', 'as problem details';

$res = $client->get('/feed');
is $res->content, "one\ntwo\n", '/feed streams';
hooks_ran($res, '/feed');

$res = $client->get('/broken');
is [$res->status, $res->content], [500, "Something went wrong\n"],
    'a handler that dies: the error handler replaces the body';
hooks_ran($res, '/broken');

done_testing;
