package Module::Build::Platform::Unix;

use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;
use Module::Build::Base;

use vars qw(@ISA);
@ISA = qw(Module::Build::Base);

sub is_executable {

    my ( $self, $file ) = @_;
    return +( stat $file )[2] & 0100;
}

sub _startperl { "#! " . shift()->perl }

sub _construct {
    my $self = shift()->SUPER::_construct(@_);

    my $c = $self->{config};
    for (qw(siteman1 siteman3 vendorman1 vendorman3)) {
        $c->{"install${_}dir"} ||= $c->{"install${_}"};
    }

    return $self;
}

sub _detildefy {
    my ( $self, $value ) = @_;
    $value =~ s[^~([^/]+)?(?=/|$)]   # tilde with optional username
    [$1 ?
     ((getpwnam $1)[7] || "~$1") :
     ($ENV{HOME} || (getpwuid $>)[7])
    ]ex;
    return $value;
}

1;
__END__


