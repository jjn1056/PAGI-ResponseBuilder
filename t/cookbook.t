#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin;

use Cwd ();
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use PAGI::ResponseBuilder;
use PAGI::Test::Client;

# The COOKBOOK recipes run exactly as published: each =head2's indented
# verbatim paragraphs, joined in order, run against a fresh builder in $res,
# and the response it then sends is checked.

# The class "A response class of your own" names.
BEGIN {
    package My::Response::CSV;
    require PAGI::Response;
    our @ISA = ('PAGI::Response');
    sub default_content_type { 'text/csv' }
    sub render { my ($self, $rows) = @_; join '', map { join(',', @$_) . "\n" } @$rows }
    $INC{'My/Response/CSV.pm'} = __FILE__;
}

sub recipes {
    my $pod = do {
        open my $fh, '<', "$FindBin::Bin/../lib/PAGI/ResponseBuilder.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($section) = $pod =~ /^=head1 COOKBOOK\n(.*?)^=head1 /ms or die 'no COOKBOOK';
    my %code;
    my (undef, @recipes) = split /^=head2 /m, $section;    # the first part is the intro
    for my $recipe (@recipes) {
        my ($title, $body) = $recipe =~ /\A(.+?)\n(.*)\z/s or next;
        $code{$title} = join "\n",
            map  { s/^    //mgr }
            grep { /\A[ \t]/ } split /\n{2,}/, $body =~ s/\A\n+//r;
    }
    return \%code;
}

sub run_recipe {
    my ($title, $code) = @_;
    my $res = eval "package My::Cookbook; use Future::AsyncAwait;\n"
        . "my \$res = PAGI::ResponseBuilder->new;\n#line 1 \"$title\"\n$code;\n\$res";
    is $@, '', "'$title' runs as published" or return;
    ok length $code, "'$title' has code" or return;
    return PAGI::Test::Client->new(app => $res->to_app)->get('/');
}

my %checks = (
    'Text with a status' => sub {
        is $_->status, 201;
        is $_->content, "Created\n";
    },
    'JSON, with a header and a cookie collected first' => sub {
        is $_->json, { id => 7, name => 'ada' };
        is $_->header('x-request-id'), 'req-42', 'the before-hook header is kept';
        like $_->header('set-cookie'), qr/\Asession=abc123; .*HttpOnly/i, 'and the session cookie';
    },
    'HTML' => sub {
        is $_->header('content-type'), 'text/html; charset=utf-8';
        is $_->content, '<p>Hello, <b>world</b></p>';
    },
    'A redirect after a form post, keeping a cookie' => sub {
        is $_->status, 303;
        is $_->header('location'), '/items/7';
        like $_->header('set-cookie'), qr/\Aflash=saved;/;
    },
    'No content' => sub {
        is $_->status, 204;
        is $_->content, '';
    },
    'A Problem details error' => sub {
        is $_->status, 409;
        is $_->header('content-type'), 'application/problem+json';
        is $_->json->{title}, 'Out of stock';
    },
    'A file download' => sub {
        is $_->status, 200;
        like $_->header('content-disposition'), qr/attachment; filename="october\.csv"/;
        is $_->content, "id,total\n7,42\n", 'the file itself is sent';
    },
    'A streamed body' => sub {
        is $_->header('content-type'), 'text/csv';
        is $_->content, "id,name\n7,ada\n";
    },
    'Text in a charset other than UTF-8' => sub {
        is $_->header('content-type'), 'text/plain; charset=iso-8859-1';
        is $_->content, "caf\xE9", 'one Latin-1 byte for the e-acute';
    },
    'Replacing the body when the handler fails' => sub {
        is $_->status, 500;
        is $_->content, 'Internal Server Error';
        is $_->header('x-request-id'), 'req-42', 'the collected header survives the new body';
    },
    'A response class of your own' => sub {
        is $_->header('content-type'), 'text/csv';
        is $_->content, "id,name\n7,ada\n";
    },
);

# The file "A file download" sends, relative to where the recipes run.
my $root = tempdir(CLEANUP => 1);
make_path("$root/reports");
open my $csv, '>', "$root/reports/2026-10.csv" or die $!;
print {$csv} "id,total\n7,42\n";
close $csv;

my $recipes = recipes();

# Response classes load when a recipe first names them, so @INC must still
# resolve once the recipes run from $root.
@INC = map { ref($_) || !-d $_ ? $_ : Cwd::abs_path($_) } @INC;
chdir $root or die "chdir $root: $!";
is [sort keys %$recipes], [sort keys %checks], 'every recipe has checks, and every check a recipe';

for my $title (sort keys %$recipes) {
    subtest $title => sub {
        my $sent = run_recipe($title, $recipes->{$title}) or return;
        local $_ = $sent;
        ($checks{$title} // sub { fail "no checks for '$title'" })->();
    };
}

done_testing;
