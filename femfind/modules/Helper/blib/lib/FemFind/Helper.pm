package FemFind::Helper;

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

require Exporter;
require AutoLoader;

@ISA = qw(Exporter AutoLoader);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@EXPORT = qw(
	
);

@EXPORT_OK = qw(
	&get_ip &shell_escape &get_time_decrement
);

$VERSION = '0.72';


# Preloaded methods go here.
sub get_ip
{
	(my $host, my $wg, my $csmb_path, my $csmb_accparam, my $debug, my $dbg) = @_;
	print $dbg "get_ip: $host" if ($debug);
	
	# ip address? then we're done
	if ($host =~ m/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/)
	{
		return $host;
	}
	
	# first try nmblookup
	my $hb = $host;
	$host = shell_escape($host);
	my $out = `$csmb_path/nmblookup \"$host\"`;
	print $dbg $out if ($debug);
	if ($? == 0 && $out =~ m/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) /m)
	{
		return $1;
	}
	
	# some hosts can not be resolved with nmblookup
	# so let's try a simple smbclient connect
	my $wgstr = $wg eq '' ? '' : '-W "' . shell_escape($wg) . '"';
	my @smbc = `$csmb_path/smbclient \"//$host/\" $csmb_accparam -L \"$host\" $wgstr`;
	foreach (@smbc)
	{
	  if (/positive name.*?\( (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) \)/)
	  {
		  return $1;
	  }
	}
	
	# last ressort: maybe it's a dns address already
	# if we can ping it we'll accept it
	system("ping -c1 -i1 -w1 \"$host\" >/dev/null 2>/dev/null");
	if ($? == 0)
	{
	  return $hb;
	}
	
	# no ip found
	print $dbg "get_ip: could not resolve\n" if ($debug);
	return undef;
}

sub shell_escape
{
	my ($tmp) = @_;
	$tmp =~ s/(\$|\"|\`)/\\$1/g;
	return $tmp;
	
#` to fool syntax highlighting ;) 
}

sub get_time_decrement
{
	my ($time, $dec) = @_;
	my $hour = int $time/100;
	my $min = $time % 100;
	$hour -= $dec;
	$hour += 24 if ($hour < 0);
	return ($hour * 100 + $min);
}

# Autoload methods go after =cut, and are processed by the autosplit program.

1;
__END__
# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

FemFind::Helper - additional module for FemFind

=head1 SYNOPSIS

  use FemFind::Helper;

=head1 DESCRIPTION

Internal FemFind module.

=head1 AUTHOR

Martin Richtarsky, ai3@codefactory.de

=head1 SEE ALSO

perl(1), FemFind README.

=cut
