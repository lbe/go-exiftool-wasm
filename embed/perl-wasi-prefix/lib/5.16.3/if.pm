package if;

$VERSION = '0.0602';

sub work {
    my $method = shift() ? 'import' : 'unimport';
    die
"Too few arguments to 'use if' (some code returning an empty list in list context?)"
      unless @_ >= 2;
    return unless shift;

    my $p = $_[0];
    ( my $file = "$p.pm" ) =~ s!::!/!g;
    require $file;
    my $m = $p->can($method);
    goto &$m if $m;
}

sub import   { shift; unshift @_, 1; goto &work }
sub unimport { shift; unshift @_, 0; goto &work }

1;
__END__


