package Module::Build::Platform::cygwin;

use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;
use Module::Build::Platform::Unix;

use vars qw(@ISA);
@ISA = qw(Module::Build::Platform::Unix);

sub manpage_separator {
    '.';
}

sub _maybe_command {
    my ( $self, $file ) = @_;

    if ( $file =~ m{^/cygdrive/}i ) {
        require Module::Build::Platform::Windows;
        return Module::Build::Platform::Windows->_maybe_command($file);
    }

    return $self->SUPER::_maybe_command($file);
}

1;
__END__


