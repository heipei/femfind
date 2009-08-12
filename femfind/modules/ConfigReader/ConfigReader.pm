package FemFind::ConfigReader;

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
use vars qw(%c %mod);

require Exporter;
require AutoLoader;

use FemFind::Helper qw(get_time_decrement shell_escape);

@ISA = qw(Exporter AutoLoader);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@EXPORT = qw(
	
);

@EXPORT_OK = qw(
	&config_read &config_default &config_check &config_error
);

$VERSION = '0.74';

# Preloaded methods go here.

my %mod = ();
%c = (CONFIG_FILE=>'/etc/femfind.conf');

sub config_default
{
	# these parameters must be defined
	$mod{SMB_MASTERBROWSER} = $mod{SMB_MB_WORKGROUP} = $mod{LOGFILE_PATH} =
	$mod{SMB_PATH} = $mod{DEBUGLEVEL} = $mod{DB_MODFILE_PATH} =
	$mod{FTPFILE} = $mod{DB_CRAWLER_LOGIN} =
	$mod{DB_NAME} = $mod{FTP_ANON_PW} = $mod{SMB_EXPIRE} = $mod{FTP_EXPIRE} =
	$mod{TIME_WINDOW} = $mod{LOCKFILE_PATH} = $mod{BACKUP_URL} = 
	$mod{DB_BASE} = $mod{SMB_USER} = $mod{CRAWL_HIDDEN} = 1;

	# these are optional
	$mod{DB_PARAMETER} = $mod{SMB_PASSWORD} = $mod{DISABLE_FTP} =
	$mod{DISABLE_SMB} = 0;
	
	$c{DEBUGLEVEL} = 3;
	$c{FTP_ANON_PW} = 'femfind@fem';
	$c{SMB_EXPIRE} = 4;
	$c{FTP_EXPIRE} = 8;
	$c{TIME_WINDOW} = 2; # window for PreferedTime in hours
	
	$c{VERSION} = '0.74';
	$c{VDATE} = '2000-11-24';
	$c{SMB} = 1;
	$c{FTP} = 2;
	$c{CRAWL_MAIN} = 1;
	$c{CRAWL_HOUR} = 2;
	$c{MOD_EDIT} = 3;
	$c{MAKE_TABLES} = 9;
	$c{MAX_BATCH} = 100; # max joined insert/delete statements
	$c{DATE} = time;
	$c{BACKUP_URL} = '';
	
	my ($sec, $min, $hour) = localtime(time);
	$c{TIME_MAX} = $hour * 100 + $min;;
	$c{TIME_MIN} = get_time_decrement($c{TIME_MAX}, $c{TIME_WINDOW});
	$c{ERR_FATAL} = "Fatal error: Please check logfile\n";
	
	$c{MONTHS} = {'Jan'=>'01', 'Feb'=>'02', 'Mar'=>'03',
	'Apr'=>'04', 'May'=>'05','Jun'=>'06',
	'Jul'=>'07', 'Aug'=>'08', 'Sep'=>'09',
	'Oct'=>'10','Nov'=>'11', 'Dec'=>'12'};
	
	return %c;
}

sub config_read
{
	my ($msges) = @_;
	
	open (IN, "<$c{CONFIG_FILE}") || die "Could not open $c{CONFIG_FILE}\nReason: $!\n";
	while ($_ = <IN>)                                                                                                           
	{                                                                                                                           
		next if /^#/ || /^$/;
		
		/(\S+)\s+(.*)$/;

		my $var = uc $1;                                                                                                    
		if (defined $mod{$var})                                                                                             
		{                                                                                                                   
			$c{$var} = $2;                                                                                              
		}                                                                                                                   
		elsif ($msges == 1)
		{                                                                                                                   
			print("config_read: invalid entry $var\n");
		}                                                                                                                   
	}                                                                                                                           
	close IN;
	
	# provide the concatenated db name
	$c{DB} = $c{DB_BASE} . $c{DB_NAME} . $c{DB_PARAMETER};
	
	# and build the auth string
	$c{SMB_ACCPARAM} = '-U "' . shell_escape($c{SMB_USER}) . '%'
			   . shell_escape($c{SMB_PASSWORD}) . '"';
				
	return %c;
}

sub config_check                                                                                                                    
{                                                                                                                                   
	my $error = 0;                                                                                                              
	
	foreach (keys %mod)
	{                                                                                                                           
		if (!defined $c{$_} && $mod{$_} == 1)
		{                                                                                                                   
			print "config_check: error. parameter $_ must be specified in femfind.conf\n";
			$error++;                                                                                                   
		}
	}
	$c{CRAWL_HIDDEN} = lc $c{CRAWL_HIDDEN};
	$c{DISABLE_SMB} = lc $c{DISABLE_SMB};
	$c{DISABLE_FTP} = lc $c{DISABLE_FTP};
	$error += check_yes_no('CRAWL_HIDDEN');
	$error += check_yes_no('DISABLE_SMB');
	$error += check_yes_no('DISABLE_FTP');
	return $error;
}

sub check_yes_no
{
    my ($option) = @_;

    if ($c{$option} ne 'yes' && $c{$option} ne 'no')
    {
	print "config_check: error. $option must be defined (values: yes or no)\n",
	    "	current value is $c{option}\n";
	return 1;
    }
    return 0;
}

sub config_error
{
    print "Configuration is not complete.\nPlease check /etc/femfind.conf!\n";
}

# Autoload methods go after =cut, and are processed by the autosplit program.

1;
__END__
# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

FemFind::ConfigReader - additional module for FemFind

=head1 SYNOPSIS

  use FemFind::ConfigReader;
  my %c = config_default();
  %c = config_read(1);
  if (config_check() != 0)
  {
	  config_error();
	  exit 1;
  }

=head1 DESCRIPTION

Internal FemFind module.

=head1 AUTHOR

Martin Richtarsky, ai3@codefactory.de

=head1 SEE ALSO

perl(1), FemFind README.

=cut
