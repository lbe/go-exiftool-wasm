package Module::Build::Platform::os2;

use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;
use Module::Build::Platform::Unix;

use vars qw(@ISA);
@ISA = qw(Module::Build::Platform::Unix);

sub manpage_separator { '.' }

sub have_forkpipe { 0 }

sub _maybe_command {
    my ( $self, $file ) = @_;
    $file =~ s,[/\\]+,/,g;
    return $file       if -x $file       && !-d _;
    return "$file.exe" if -x "$file.exe" && !-d _;
    return "$file.cmd" if -x "$file.cmd" && !-d _;
    return;
}

1;
__END__


