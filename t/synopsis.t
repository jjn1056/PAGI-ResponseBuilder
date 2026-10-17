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
    is $res->header('x-request-id'), 'req-42', "$label: the header collected first is sent";
    like $res->header('set-cookie'), qr/\Asession=abc123;/, "$label: and the cookie";
}

my $res = $client->get('/');
is [$res->status, $res->content], [200, "Hello\n"], '/ is text';
hooks_ran($res, '/');

$res = $client->post('/items');
is $res->status, 201, '/items is a 201';
is $res->json, { id => 7, name => 'ada' }, 'with a JSON body';
hooks_ran($res, '/items');

$res = $client->get('/old');
is [$res->status, $res->header('location')], [301, '/'], '/old redirects';
hooks_ran($res, '/old');

$res = $client->get('/nowhere');
is $res->status, 404, 'anything else is a 404';
is $res->header('content-type'), 'application/problem+json', 'as problem details';
hooks_ran($res, '/nowhere');

# The subclass the second half defines.
my $mine = My::Response->new;
isa_ok $mine, 'PAGI::ResponseBuilder';
$res = PAGI::Test::Client->new(app => $mine->text('hi')->to_app)->get('/');
is $res->header('x-powered-by'), 'My::Framework', 'its constructor adds the default header';

$res = PAGI::Test::Client->new(app => My::Response->new->not_found('no item 9')->to_app)->get('/');
is $res->status, 404, 'not_found is a 404';
is $res->json->{detail}, 'no item 9', 'with the detail given';
is $res->header('x-powered-by'), 'My::Framework', 'and the default header';

done_testing;
