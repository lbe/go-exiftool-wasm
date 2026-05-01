package Module::Build;

use strict;
use File::Spec     ();
use File::Path     ();
use File::Basename ();
use Perl::OSType   ();

use Module::Build::Base;

use vars qw($VERSION @ISA);
@ISA     = qw(Module::Build::Base);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;

sub _interpose_module {
    my ( $self, $mod ) = @_;
    eval "use $mod";
    die $@ if $@;

    no strict 'refs';
    my $top_class = $mod;
    while ( @{"${top_class}::ISA"} ) {
        last if ${"${top_class}::ISA"}[0] eq $ISA[0];
        $top_class = ${"${top_class}::ISA"}[0];
    }

    @{"${top_class}::ISA"} = @ISA;
    @ISA = ($mod);
}

if (
    grep {
        -e File::Spec->catfile( $_, qw(Module Build Platform), $^O ) . '.pm'
    } @INC
  )
{
    __PACKAGE__->_interpose_module("Module::Build::Platform::$^O");

}
elsif ( my $ostype = os_type() ) {
    __PACKAGE__->_interpose_module("Module::Build::Platform::$ostype");

}
else {
    warn "Unknown OS type '$^O' - using default settings\n";
}

sub os_type { return Perl::OSType::os_type() }

sub is_vmsish     { return Perl::OSType::is_os_type('VMS') }
sub is_windowsish { return Perl::OSType::is_os_type('Windows') }
sub is_unixish    { return Perl::OSType::is_os_type('Unix') }

1;

__END__

