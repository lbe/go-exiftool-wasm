package File::Spec;

use strict;
use vars qw(@ISA $VERSION);

$VERSION = '3.39_02';
$VERSION =~ tr/_//;

my %module = (
    MacOS   => 'Mac',
    MSWin32 => 'Win32',
    os2     => 'OS2',
    VMS     => 'VMS',
    epoc    => 'Epoc',
    NetWare => 'Win32', symbian => 'Win32', dos => 'OS2', cygwin => 'Cygwin'
);

my $module = $module{$^O} || 'Unix';

require "File/Spec/$module.pm";
@ISA = ("File::Spec::$module");

1;

__END__

