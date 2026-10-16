# PAGI-ResponseBuilder dependencies
# Install with: cpanm --installdeps .

requires 'perl', '5.018';

# The response values the builder makes
requires 'PAGI::Tools', '0.003000';

# Testing
on 'test' => sub {
    requires 'Test2::V0', '0.000159';
    requires 'Future', '0.50';
};

# Development
on 'develop' => sub {
    requires 'Dist::Zilla', '6.030';
    requires 'Dist::Zilla::Plugin::MetaJSON';
    requires 'Dist::Zilla::Plugin::MetaResources';
    requires 'Dist::Zilla::Plugin::Prereqs::FromCPANfile';
    requires 'Dist::Zilla::Plugin::PkgVersion';
    requires 'Dist::Zilla::Plugin::ReadmeAnyFromPod';
};
