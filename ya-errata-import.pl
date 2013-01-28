#!/usr/bin/perl

# This script imports CentOS or RedHat Errata into your Spacewalk
# It relies on preformatted information since parsing email
# is the road to madness...
#
# To run this script you need perl-Text-Unidecode
#
# Based on: centos-errata-import.pl and eva-direct-errata-sync.pl
#    Authors: Steve Meier (centos-errata-import.pl)
#             Paul Roberts (eva-direct-errata-sync.pl)
# Author: Franky Van Liedekerke
# 20121010 - add option to use RHN to get details
#          - only consider one channel and architecture at a time, to avoid
#            redhat/centos issues and cross-basechannel copies of packages
#          - add support for redhat errata and servers
#          - time ranges
# 20130125 - added commandline options for usernames and pwds

# Load modules
use strict;
use warnings;

use Data::Dumper;
use Getopt::Long;
use Text::Unidecode;
use Frontier::Client;

#######################################################################
### GLOBAL VARIABLES
#######################################################################

# Version information
my $version = "20130128";
my @supportedapi = ( '10.9','10.11','11.00','11.1' );

# Spacewalk Version => API cheatsheet
# 0.6 => 10.9  == TESTED
# 0.7 => ??
# 0.8 => ??
# 1.0 => 10.11
# 1.1 => 10.11 == TESTED
# 1.2 => 10.15
# 1.3 => ??
# 1.4 => 10.16
# 1.5 => 11.00 == TESTED
# 1.6 => 11.1  == TESTED
# 1.7 => 11.1  == TESTED

# Variable declation
$| = 1;
my ($client,$rhn_client);
my $apiversion;
my $apisupport = 0;
my ($xml, $rhsaxml);
my ($session, $username, $password,$rhn_session,$rhn_username,$rhn_password);
#my %name2channel;
my %name2id;
my ($channellist, $channel, @excludechannels);
my ($channeldetails, $lastmodified, $trackmodified, $lastsync, $synctimestamp);
my ($reference, %erratadetails, %erratainfo);
my $result;
my $undopush;
my ($pkg, $allpkg, $pkgdetails, $package);
my ($advisory, $ovalid);
my $getdetails;
my $os_variant; # Either 'C' for CentOS or 'R' for RedHat

my $opt_syncchannels = 0;
my $opt_synccounter = 0;
my $opt_synctimeout = 600;
my $opt_channel;
my $opt_rhsaovalfile="";
my $opt_erratadir;
my $opt_server;
my $opt_publish = 0; # do not publish by default
my $opt_get_from_rhn = 0;
my $opt_security = 0;
my $opt_bugfix = 0;
my $opt_enhancement = 0;
my $opt_debug = 0;
my $opt_quiet = 0;
my $opt_os_version = 0;
my $opt_help;
my $opt_autopush = 0;
my $opt_architecture; 
my $opt_redhat = 0;
my $opt_rhn_proxy="";
my $opt_rhn_server="rhn.redhat.com";
my $opt_bugzilla_url="https://bugzilla.redhat.com/";
my $opt_proxy="";
my $opt_redhat_startfromprevious;
my $opt_redhat_startdate;
my $opt_redhat_enddate;
my $opt_redhat_channel;
my $opt_spacewalk_user;
my $opt_spacewalk_pwd;
my $opt_rhn_user;
my $opt_rhn_pwd;

#######################################################################
### PROCEDURES
#######################################################################

sub debug() {
  print "DEBUG: @_" if ($opt_debug);
}

sub info() {
  print "INFO: @_" if (!$opt_quiet);
}

sub warning() {
  print "WARNING: @_";
}

sub error() {
  print "ERROR: @_";
}

sub usage() {
  print "Script to clone errata for CentOS or RedHat into Spacewalk\n";
  print "\nUsernames and passwords are best taken from the environment\n";
  print "variables SPACEWALK_USER, SPACEWALK_PASS, RHN_USER, RHN_PASS\n";
  print "You can also provide them using the available options (see below),\n";
  print "if you do so, the commandline options take precedence over the ENV variables\n";
  print "Otherwise you'll be asked for it if not given but needed.\n\n";
  print "Usage: $0 --server <SERVER> --erratadir <ERRATA-DIR> \n";
  print "         --channel=<CHANNEL> --os-version <VERSION>\n";
  print "       [ --rhsa-oval <REDHAT-OVAL-XML> | --debug |\n";
#  print "         --sync-channels | --sync-timeout=<TIMEOUT> |\n";
  print "         --bugfix | --security | --enhancement |\n";
#  print "         --autopush ]\n";
  print "         --publish | --quiet | --get-from-rhn | -- architecture <ARCH> |\n";
  print "         --rhn-proxy <PROXY> | --rhn-server <RHNSERVER> |\n";
  print "         --spacewalk-user <USER> | --spacewalk-pass <PWD> |\n";
  print "         --rhn-user <RHNUSER> | --rhn-pass <RHNPWD> |\n";
  print "         --proxy <PROXY> | --bugzilla-url <URL> ]\n";
  print "\n";
  print "REQUIRED:\n";
  print "  --server\t\tThe hostname or IP address of your spacewalk server\n";
  print "  --channel\t\tThe spacewalk channel you want to publish errata to\n";
  print "  --os-version\t\tThe OS major version we're dealing with, used for the errata suffix\n";
  print "\n";
  print "REQUIRED for CentOS errata:\n";
  print "  --erratadir\t\tThe dir containing CentOS errata announcement digest archives\n";
  print "             \t\tSee the accompanying file centos-clone-errata.sh for an example on how to use this\n";
  print "\n";
  print "OPTIONAL:\n";
  print "  --quiet\t\tSuppresses all informational messages\n";
#  print "  --sync-channels\tSync channel with associated repository before scanning\n";
#  print "  --sync-timeout\tAbort sync after n seconds stalled (default: 600)\n";
#  print "  --autopush\t\tAllow server to copy packages around (NOT recommended)\n";
  print "  --publish\t\tPublish errata after creation (default: unpublished)\n";
  print "  --architecture\tEither 'i386','x86_64' or not specified, in which case the architecture of the channel will be taken\n";
  print "  --bugfix\t\tImport only Bug Fix Advisories (default: all)\n";
  print "  --security\t\tImport only Security Advisories (default: all)\n";
  print "  --enhancement\t\tImport only Enhancement Advisories (default: all)\n";
  print "  --rhn-proxy\t\tProxy needed to connect to RHN network\n";
  print "  --rhn-server\t\tRHN server (defaults to $opt_rhn_server)\n";
  print "  --proxy\t\tProxy to connect to spacewalk server\n";
  print "  --bugzilla-url\tPrefix for errata bugfix url, defaults to '$opt_bugzilla_url'\n";
  print "  --spacewalk-user\tthe username to connect to spacewalk (see also comments at the top)\n";
  print "  --spacewalk-pass\tthe password to connect to spacewalk (see also comments at the top)\n";
  print "  --rhn-user\t\tthe username to connect to RHN (see also comments at the top)\n";
  print "  --rhn-pass\t\tthe password to connect to RHN (see also comments at the top)\n";
  print "\n";
  print "OPTIONAL for CentOS errata:\n";
  print "  --rhsa-oval\t\tOVAL XML file from Red Hat\n";
  print "  --get-from-rhn\tIndicate that you want to get extra info from RHN for CentOS errata\n";
  print "\n";
  print "OPTIONAL for RedHat errata:\n";
  print "  --redhat\t\tUse RedHat for errata cloning, if not set CentOS is assumed\n";
  print "  --redhat-channel\tRedHat channel to get errata from, only usefull with --redhat, defaults to the same as --channel\n";
  print "  --redhat-startdate\tThe start date for the errata\n";
  print "  --redhat-startfromprevious\tStart from previous hour,day,week,twoweeks,month,year (these are the possible values)\n";
  print "  --redhat-enddate\tThe end date for the errata\n";
  print "\n";
  print "DEBUGGING:\n";
  print "  --debug\t\tSet verbosity to debug (use this when reporting issues!)\n";
  print "\n";
}

sub uniq() {
  my %all = ();
  @all{@_} = 1;
  return (keys %all);
}

sub parse_redhat_errata($$) {
  my ($client,$sessionid)=@_;
  my $xml;
  my $rhn_erratas;

  &set_proxy($opt_rhn_proxy);
  if (defined($opt_redhat_startfromprevious)) {
     my $startdate=&get_previous_startdate($opt_redhat_startfromprevious);
     &info("Getting erratas from date $startdate till now\n");
     $rhn_erratas = $client->call('channel.software.listErrata',$sessionid,$opt_redhat_channel,$startdate);
  } elsif (defined($opt_redhat_startdate) && defined($opt_redhat_enddate)) {
     &info("Getting erratas from date $opt_redhat_startdate till $opt_redhat_enddate\n");
     $rhn_erratas = $client->call('channel.software.listErrata',$sessionid,$opt_redhat_channel,$opt_redhat_startdate,$opt_redhat_enddate);
  } elsif (defined($opt_redhat_startdate)) {
     &info("Getting erratas from date $opt_redhat_startdate till now\n");
     $rhn_erratas = $client->call('channel.software.listErrata',$sessionid,$opt_redhat_channel,$opt_redhat_startdate);
  } else {
     &info("Getting ALL erratas (this make take a while)\n");
     $rhn_erratas = $client->call('channel.software.listErrata',$sessionid,$opt_redhat_channel);
  }
  foreach my $errata (@$rhn_erratas) {
	my $advid=$errata->{'errata_advisory'};
        my $rhn_errata_details=&rhn_get_details($rhn_client,$rhn_session,$advid);
        my @rhn_errata_packages=&rhn_get_packages($rhn_client,$rhn_session,$advid);

        # the Redhat API call returns errata_notes and such, spacewalk needs just "notes" and alike
	$xml->{$advid}={};
	$xml->{$advid}->{'synopsis'}=$errata->{'errata_synopsis'};
	$xml->{$advid}->{'release'}=1;
	$xml->{$advid}->{'type'}=$errata->{'errata_advisory_type'};
	$xml->{$advid}->{'advisory_name'}=$errata->{'errata_advisory'};
	$xml->{$advid}->{'product'}="RHEL Linux";
	$xml->{$advid}->{'topic'}=$rhn_errata_details->{'errata_topic'};
	$xml->{$advid}->{'description'}=$rhn_errata_details->{'errata_description'};
	$xml->{$advid}->{'notes'}=$rhn_errata_details->{'errata_notes'};
	$xml->{$advid}->{'solution'}="not available";
	#$xml->{$advid}->{'os_release'}=$os_release;
	$xml->{$advid}->{'references'}=$rhn_errata_details->{'errata_references'};
	$xml->{$advid}->{${opt_architecture}.'_packages'}=\@rhn_errata_packages;
  }
  &set_proxy($opt_proxy);
  return $xml;
}

sub parse_archivedir() {
  opendir(my $dh, $opt_erratadir) || die "can't opendir $opt_erratadir: $!";
  my @files = grep { !/^\./ && -f "$opt_erratadir/$_" } readdir($dh);
  closedir $dh;

  my $xml;

  foreach my $file (@files) {
	local $/=undef;
	open(IN,"$opt_erratadir/$file");
	my $string = <IN>;
	close(IN);
	local $/="\n";
	
	my @parts = split(/Message:/,$string);
	# skip the first part, since it's general info
	shift(@parts);
	foreach my $part (@parts) {
		if ($part !~ /Subject: \[CentOS-announce\] CE/s) {
			next;
		}
		(my $subject = $part) =~ s/.*Subject: \[CentOS-announce\] (CE.*?)To:.*/$1/s;
		(my $upstream_details = $part) =~ s/.*Upstream details at : (.*?)\n.*/$1/s;
		$subject =~ s/\n//gs;
		$subject =~ s/\s+/ /g;
		$upstream_details =~ s/.*\>(.*)\<.*/$1/;
		(my $advid = $subject) =~ s/(.*?) .*/$1/;
		(my $synopsis = $subject) =~ s/.*? (.*)/$1/;
		(my $os_release = $subject) =~ s/.* (\d+) .*/$1/;

		# now get the packages per architecture
		my $i386_packages="";
		my $x86_64_packages="";
		($part =~ /i386:/s) && (($i386_packages = $part) =~ s/.*i386:\n(.*?)\n\n.*/$1/s);
		($part =~ /x86_64:/s) && (($x86_64_packages = $part) =~ s/.*x86_64:\n(.*?)\n\n.*/$1/s);
		my @i386_packages = split(/\n/s,$i386_packages);
		my @x86_64_packages = split(/\n/s,$x86_64_packages);
		# remove the checksum info
		s/\S+\s+// for @i386_packages;
		s/\S+\s+// for @x86_64_packages;
		
		my $adv_type="";
		if (substr($advid,2,2) eq "SA") { $adv_type="Security Advisory";}
		elsif (substr($advid,2,2) eq "BA") { $adv_type="Bug Fix Advisory";}
		elsif (substr($advid,2,2) eq "EA") { $adv_type="Product Enhancement Advisory";}
		else {
			# something undetermined: we skip it
			next;
		}
		$xml->{$advid}={};
		$xml->{$advid}->{'synopsis'}=$synopsis;
		$xml->{$advid}->{'release'}=1;
		$xml->{$advid}->{'type'}=$adv_type;
		$xml->{$advid}->{'advisory_name'}=$advid;
		$xml->{$advid}->{'product'}="CentOS Linux";
		$xml->{$advid}->{'topic'}="not available";
		$xml->{$advid}->{'description'}="not available";
		$xml->{$advid}->{'notes'}="not available";
		$xml->{$advid}->{'solution'}="not available";
		$xml->{$advid}->{'os_release'}=$os_release;
		$xml->{$advid}->{'references'}="$upstream_details";
		# depending on the value off opt_acrhitecture, one of the following 2 will be used
		$xml->{$advid}->{'i386_packages'}=\@i386_packages;
		$xml->{$advid}->{'x86_64_packages'}=\@x86_64_packages;
	}
  }
  return $xml;
}

sub channel_get_details($$$) {
    my ($client,$sessionid,$channel_label)=@_;
    my $details=$client->call('channel.software.getDetails',$sessionid,$channel_label);
    return $details;
}

sub rhn_get_details($$$) {
    my ($client,$sessionid,$advisory_name)=@_;
    $advisory_name =~ s/CE/RH/g;
    my $details=$client->call('errata.getDetails',$sessionid,$advisory_name);
    return $details;
}

sub rhn_get_keywords($$$) {
    my ($client,$sessionid,$advisory_name)=@_;
    $advisory_name =~ s/CE/RH/g;
    #my @keywords=eval($client->call('errata.listKeywords',$sessionid,$advisory_name));
    my $keywords=$client->call('errata.listKeywords',$sessionid,$advisory_name);
    if (wantarray) {
        return @{$keywords};
    } else {
	return $keywords;
    }
}
sub rhn_get_bugs($$$$) {
    my ($client,$sessionid,$advisory_name,$bugzilla_url)=@_;
    $advisory_name =~ s/CE/RH/g;
    my $bugzilla='';
    if ($bugzilla_url) {
        $bugzilla=$bugzilla_url . 'show_bug.cgi?id=';
    }
    my $raw_bugs=$client->call('errata.bugzillaFixes',$sessionid,$advisory_name);
    my @bugs;
    foreach my $key (keys %{$raw_bugs}) {
        my $bug= {
            'id'=>$key,
            'summary'=>$raw_bugs->{$key},
            'url'=>''
        };
        if ($bugzilla) {
            $bug->{'url'}=$bugzilla . $key;
        }
        push(@bugs,$bug);
    }
    if (wantarray) {
        return @bugs;
    } else {
	return \@bugs;
    }
}

sub rhn_get_packages($$$) {
    my ($client,$sessionid,$advisory_name)=@_;
    $advisory_name =~ s/CE/RH/g;
    my $packages=$client->call('errata.listPackages',$sessionid,$advisory_name);
    my @packages;
    foreach my $pkg (@$packages) {
		my $found=0;
		foreach my $providing_channel (@{$pkg->{'providing_channels'}}) {
         if ((!$opt_redhat && $providing_channel eq $opt_channel) ||
             ($opt_redhat && $providing_channel eq $opt_redhat_channel)) {
				$found=1;
			}
		}
		(!$found) && (next);
		push(@packages,$pkg->{'package_file'});
    }
    return @packages;
}

sub rhn_get_cves($$$) {
    my ($client,$sessionid,$advisory_name)=@_;
    $advisory_name =~ s/CE/RH/g;
    my $cve=$client->call('errata.listCves',$sessionid,$advisory_name);
    if (wantarray) {
        return @{$cve};
    }
    else{return $cve;}
}

sub get_previous_startdate($) {
    my $previous=$_[0];
    my $minute=60;
    my $hour=60*$minute;
    my $day=24*$hour;
    my $week=7*$day;
    my $month=31*$day; # 31 days better safe than sorry
    my $year=366*$day; # 365 days plus 1 for leap year
    my $current_time=time;
    if ($previous=~/^(m|minute)$/i){
        $current_time=$current_time - $minute;
    }
    elsif ($previous=~/^hour$/i){
        $current_time=$current_time - $hour;
    }
    elsif ($previous=~/^day$/i){
        $current_time=$current_time - $day;
    }
    elsif ($previous=~/^week$/i){
        $current_time=$current_time - $week;
    }
    elsif ($previous=~/^twoweeks$/i){
        $current_time=$current_time - 2*$week;
    }
    elsif ($previous=~/^month$/i){
        $current_time=$current_time - $month;
    }
    elsif ($previous=~/^year$/i){
        $current_time=$current_time - $year;
    }
    else{
        return "";
    }
    my @time=localtime($current_time);
    my $old_year=$time[5]+1900;
    my $old_month=$time[4] + 1;
    #my $previousdate=$old_year . '-' . $old_month . '-' . pad_time($time[3]) . ' ' . pad_time($time[2]) . ':' . pad_time($time[1]) . ':' . pad_time($time[0]);
    my $previousdate=sprintf("%d-%02d-%02d %02d:%02d:%02d",$old_year,$old_month,$time[3],$time[2],$time[1],$time[0]);
    return $previousdate;
}

sub set_proxy($) {
   my $proxy=$_[0];
   if ($proxy ne "") {
      $ENV{'HTTPS_PROXY'}=$proxy;
      $ENV{'HTTP_PROXY'}=$proxy;
      $ENV{'https_proxy'}=$proxy;
      $ENV{'http_proxy'}=$proxy;
   } else {
      delete($ENV{'HTTPS_PROXY'});
      delete($ENV{'HTTP_PROXY'});
      delete($ENV{'https_proxy'});
      delete($ENV{'http_proxy'});
   }
}

#######################################################################
### MAIN
#######################################################################

# Print call and parameters if in debug mode (GetOptions will clear @ARGV)
if (join(' ',@ARGV) =~ /--debug/) { print STDERR "DEBUG: Called as $0 ".join(' ',@ARGV)."\n"; }

# Parse arguments
my $getopt = GetOptions( 'server=s'		=> \$opt_server,
                      'erratadir=s'		=> \$opt_erratadir,
                      'rhsa-oval=s'		=> \$opt_rhsaovalfile,
                      'debug'			=> \$opt_debug,
                      'publish'			=> \$opt_publish,
		      'security'		=> \$opt_security,
		      'bugfix'			=> \$opt_bugfix,
		      'help'			=> \$opt_help,
		      'architecture=s'		=> \$opt_architecture,
		      'enhancement'		=> \$opt_enhancement,
                      'sync-channels'		=> \$opt_syncchannels,
                      'sync-timeout=i'		=> \$opt_synctimeout,
                      'os-version=i'		=> \$opt_os_version,
                      'channel=s'		=> \$opt_channel,
		      'rhn-proxy=s'		=> \$opt_rhn_proxy,
		      'rhn-server=s'		=> \$opt_rhn_server,
		      'get-from-rhn'		=> \$opt_get_from_rhn,
		      'bugzilla-url'		=> \$opt_bugzilla_url,
		      'proxy=s'			=> \$opt_proxy,
                      'autopush'		=> \$opt_autopush,
                      'redhat'			=> \$opt_redhat,
                      'redhat-startdate=s'	=> \$opt_redhat_startdate,
                      'redhat-enddate=s'	=> \$opt_redhat_enddate,
                      'redhat-channel=s'	=> \$opt_redhat_channel,
                      'redhat-startfromprevious=s'=> \$opt_redhat_startfromprevious,
                      'quiet'			=> \$opt_quiet,
                      'spacewalk-user=s'	=> \$opt_spacewalk_user,
                      'spacewalk-pass=s'	=> \$opt_spacewalk_pwd,
                      'rhn-user=s'		=> \$opt_rhn_user,
                      'rhn-pass=s'		=> \$opt_rhn_pwd
                     );

# Check for arguments
if ( defined($opt_help) ) {
  &usage;
  exit 1;
}

if ( not(defined($opt_server)) || not(defined($opt_channel)) ) {
  &usage;
  exit 1;
}

if ( not(defined($opt_erratadir)) && !$opt_redhat ) {
  &usage;
  exit 1;
}
if (defined($opt_erratadir) && !$opt_redhat && not(-d $opt_erratadir)) {
  # Do we have a proper errata dir?
  &error("$opt_erratadir is not a directory!\n");
  exit 1;
}

if (!$opt_os_version) {
  &error("option 'os-version' must be defined!\n");
  exit 1;
}

# check the architecture
if (defined($opt_architecture) && $opt_architecture ne "i386" && $opt_architecture ne "x86_64") {
  &error("Architecture is not correctly set, please use 'i386' or 'x86_64' for values!\n");
  exit 1;
} elsif (!defined($opt_architecture)) {
  &info("Architecture is not specified, will try to determine it based on the channel properties of '$opt_channel'\n");
}

if ($opt_redhat && !defined($opt_redhat_channel)) {
  &info("\nno redhat channel specified, assuming the name '$opt_channel'\n\n");
  $opt_redhat_channel=$opt_channel;
}

# Set the OS variant
if ($opt_redhat) {
   $os_variant=":R";
} else {
   $os_variant=":C";
}

# Output $version string in debug mode
&debug("Version is $version\n");

#############################
# Initialize API connection #
#############################
&set_proxy($opt_proxy);
$client = new Frontier::Client(url => "http://$opt_server/rpc/api");

#########################################
# Get the API version we are talking to #
#########################################
if ($apiversion = $client->call('api.get_version')) {
  &info("Server is running API version $apiversion\n");
} else {
  &error("Could not determine API version on server\n");
  exit 1;
}

#####################################
# Check if API version is supported #
#####################################
foreach (@supportedapi) {
  if ($apiversion eq $_) {
    &info("API version is supported\n");
    $apisupport = 1;
  }
}

# In case we found an unsupported API
if (not($apisupport)) {
  &error("Your API version is not supported. Try upgrading this script.\n");
  exit 2;
}

###########################
# Authenticate to the API #
###########################
if (defined($opt_spacewalk_user)) {
   $username = $opt_spacewalk_user;
} elsif (defined($ENV{'SPACEWALK_USER'})) {
   $username = $ENV{'SPACEWALK_USER'};
} else {
   print "Please enter username: ";
   chop($username=<STDIN>);
}

if (defined($opt_spacewalk_pwd)) {
   $password = $opt_spacewalk_pwd;
} elsif (defined($ENV{'SPACEWALK_PASS'})) {
   $password = $ENV{'SPACEWALK_PASS'};
} else {
   print "Please enter password: ";
   system('stty','-echo');
   chop($password=<STDIN>);
   system('stty','echo');
   print "\n";
}

$session = $client->call('auth.login', $username, $password);
if ($session =~ /^\w+$/) {
  &info("Authentication successful\n");
} else {
  &error("Authentication FAILED!\n");
  exit 3;
} 

# For RedHat: connect to RHN
if ($opt_get_from_rhn || $opt_redhat) {
   &set_proxy($opt_rhn_proxy);
   if (defined($opt_rhn_user)) {
      $rhn_username = $opt_rhn_user;
   } elsif (defined($ENV{'RHN_USER'})) {
      $rhn_username = $ENV{'RHN_USER'};
   } else {
      print "Please enter RHN username: ";
      chop($rhn_username=<STDIN>);
   }

   if (defined($opt_rhn_pwd)) {
      $rhn_password = $opt_rhn_pwd;
   } elsif (defined($ENV{'RHN_PASS'})) {
      $rhn_password = $ENV{'RHN_PASS'};
   } else {
      print "Please enter RHN password: ";
      system('stty','-echo');
      chop($rhn_password=<STDIN>);
      system('stty','echo');
      print "\n";
   }
   $rhn_client = new Frontier::Client(url => "https://$opt_rhn_server/rpc/api");
   $rhn_session = $rhn_client->call('auth.login', $rhn_username, $rhn_password);
   &set_proxy($opt_proxy);
}

##########################
# Check user permissions #
##########################
if ($opt_publish) {
  # Publishing Errata requires Satellite or Org Administrator role
  my $userroles = $client->call('user.list_roles', $session, $username);  

  &debug("User is assigned these roles: ".join(' ', @{$userroles})."\n");

  if ( (join(' ', @{$userroles}) =~ /satellite_admin/) || 
       (join(' ', @{$userroles}) =~ /org_admin/) ||
       (join(' ', @{$userroles}) =~ /channel_admin/) ) {
    &info("User has administrator access to this server\n");
  } else {
    &error("User does NOT have administrator access\n");
    &error("You have set --publish but your user has insufficient access rights\n");
    &error("Either use an account that is Satellite/Org/Channel Administator or omit --publish\n");
    exit 1;
  }
}

########################
# Get server inventory #
########################
&info("Checking if channel $opt_channel exists on $opt_server\n");

# Get a list of all channels
$channellist = $client->call('channel.list_all_channels', $session);

#if (scalar(@includechannels) > 0) { &debug("--include-channels set: ".join(" ", @includechannels)."\n"); }
#if (scalar(@excludechannels) > 0) { &debug("--exclude-channels set: ".join(" ", @excludechannels)."\n"); }

# Go through each channel 
my $found=0;
foreach $channel (sort(@$channellist)) {
   # Check if channel is included
   if ($channel->{'label'} ne $opt_channel) {
#      &debug("Channel $channel->{'name'} ($channel->{'label'}) is NOT included\n");
      next;
   }
   $found=1;
}

if (!$found) {
  &error("Could not find the specified channel $opt_channel in $opt_server!\n");
  exit 4;
} else {

  &info("Determining architecture for channel $opt_channel\n");
  my $channel_details = channel_get_details($client, $session, $opt_channel);
  my $channel_architecture = $channel_details ->{'arch_name'};
  if (!defined($opt_architecture)) {
	  if ($channel_architecture eq "IA-32") {
		  $opt_architecture = "i386";
		  &info("Detected architecture '$opt_architecture' for channel '$opt_channel'\n");
	  } elsif ($channel_architecture eq "x86_64") {
		  $opt_architecture = "x86_64";
		  &info("Detected architecture '$opt_architecture' for channel '$opt_channel'\n");
	  } else {
		  &error("Unsupported architecture '$channel_architecture' for channel '$opt_channel'\n");
		  exit 1;
	  }
  }

  &info("Scanning channel $opt_channel\n");
  # Get all packages in current channel
  $allpkg = $client->call('channel.software.list_all_packages', $session, $opt_channel);
  # Go through each package
  foreach $pkg (@$allpkg) {

    # Get the details of the current package, for the filename (the filename is referenced in the erratum)
    # Edit: commented this, it takes way too long, we'll reconstruct the package filename ourselves
    # $pkgdetails = $client->call('packages.get_details', $session, $pkg->{id});
    my $name=$pkg->{"name"};
    my $version=$pkg->{"version"};
    my $release=$pkg->{"release"};
    my $arch_label=$pkg->{"arch_label"};
    my $filename="";

    # epoch is not being used in the package name
    #my $epoch=$pkg->{"epoch"};
    #if ($epoch) {
    #     $filename="$name-$version-$release-$epoch.$arch_label.rpm";
    #} else {
    #     $filename="$name-$version-$release.$arch_label.rpm";
    #}
    $filename="$name-$version-$release.$arch_label.rpm";

    &debug("Package ID $pkg->{'id'} is $filename\n");
    $name2id{$filename} = $pkg->{'id'};
  }
}

############################
# Read the XML errata file #
############################
&info("Loading errata\n");
if ($opt_redhat) {
  $xml = &parse_redhat_errata($rhn_client,$rhn_session);
} else {
  $xml = &parse_archivedir();
}

if (!defined($xml)) {
  &info("No errata found, nothing will happen\n");
}

##################################
# Load optional Red Hat OVAL XML #
##################################
if (-f $opt_rhsaovalfile) {
  &info("Loading Red Hat OVAL XML\n");
  if (not($rhsaxml = XMLin($opt_rhsaovalfile))) {
    &error("Could not parse Red Hat OVAL file!\n");
    exit 4;
  }

  &debug("Red Hat OVAL XML loaded successfully\n");
}

##############################
# Process errata in XML file #
##############################

# Go through each found errata
foreach my $advid (sort(keys(%{$xml}))) {
  my @packages = ();
  my @channels = ();
  my @cves = ();

  # Only consider CentOS errata
  unless($advid =~ /^CE|^RH/) { &debug("Skipping $advid\n"); next; }

  # Check command line options for errata to consider
  if ($opt_security || $opt_bugfix || $opt_enhancement) {
    if ( ($advid =~ /^..SA/) && (not($opt_security)) ) {
      &debug("Skipping $advid. Security Errata not selected.\n");
      next;
    }

    if ( ($advid =~ /^..BA/) && (not($opt_bugfix)) ) {
      &debug("Skipping $advid. Bugfix Errata not selected.\n");
      next;
    }

    if ( ($advid =~ /^..EA/) && (not($opt_enhancement)) ) {
      &debug("Skipping $advid. Enhancement Errata not selected.\n");
      next;
    }
  }

  # Start processing
  &info("Processing $advid (".$xml->{$advid}->{'synopsis'}.")\n");

  # Generate OVAL ID for security errata
  $ovalid = "";
  if ($advid =~ /CESA/) {
    $advid =~ /CESA-(\d+):(\d+)/;
    $ovalid = "oval:com.redhat.rhsa:def:$1".sprintf("%04d", $2);
    &debug("Processing $advid -- OVAL ID is $ovalid\n");
  }

  my $adv_name=$advid.$os_variant.$opt_os_version;
  if ($opt_architecture eq "i386") {
	$adv_name.="-32";
  } else {
	$adv_name.="-64";
  }
  # Check if the errata already exists
  eval {$getdetails = $client->call('errata.get_details', $session, $adv_name)};
  if ($@) {
    # Errata does not exist yet, good
    
    # Find package IDs mentioned in errata
    my $all_found=1;
    foreach $package ( @{$xml->{$advid}->{${opt_architecture}.'_packages'}} ) {
      if (defined($name2id{$package})) {
        # We found it, nice
        #&debug("Package: $package -> $name2id{$package} -> $name2channel{$package} \n");
        &debug("Package: $package -> $name2id{$package}\n");
        push(@packages, $name2id{$package});
      } else {
        # No such package, too bad
        &debug("Package: $package not found\n");
	$all_found=0;
      }
    }

    # Just in case ...
    if ($all_found) {
        @packages = &uniq(@packages);
    }

    # skip errata if not all packages are present
    if (!$all_found) {
        &info("Skipping $advid since not all packages are present\n");
	if (defined($xml->{$advid}->{'os_release'}) && ($xml->{$advid}->{'os_release'} != $opt_os_version)) {
	   &info("   this is probably ok, since I think the OS version doesn't match what you wanted\n");
	} else {
	   &info("   this should be fixed by the next channel sync, or the errata is already superseded by another one\n");
	}
	next;
    }

    # Create Errata Info hash
    %erratainfo = ( "synopsis"         => $xml->{$advid}->{'synopsis'},
                    "advisory_name"    => $adv_name,
                    "advisory_release" => int($xml->{$advid}->{'release'}),
                    "advisory_type"    => $xml->{$advid}->{'type'},
                    "product"          => $xml->{$advid}->{'product'},
                    "topic"            => $xml->{$advid}->{'topic'},
                    "description"      => $xml->{$advid}->{'description'},
                    "references"       => $xml->{$advid}->{'references'},
                    "notes"            => $xml->{$advid}->{'notes'},
                    "solution"         => $xml->{$advid}->{'solution'} );

    # Insert description from Red Hat OVAL file, if available (only for Security)
    if (defined($ovalid) && !$opt_redhat) {
      if ( defined($rhsaxml->{definitions}->{definition}->{$ovalid}->{metadata}->{description}) ) {
        &debug("Using description from $ovalid\n");
        $erratainfo{'description'} = $rhsaxml->{definitions}->{definition}->{$ovalid}->{metadata}->{description};
        # Remove Umlauts -- API throws errors if they are included
        $erratainfo{'description'} = unidecode($erratainfo{'description'});
        # Limit to length of 4000 bytes (see https://www.redhat.com/archives/spacewalk-list/2012-June/msg00128.html)
        if (length($erratainfo{'description'}) > 4000) {
          $erratainfo{'description'} = substr($erratainfo{'description'}, 0, 4000);
        } 
        # Add Red Hat's Copyright notice to the Notes field
        if ( defined($rhsaxml->{definitions}->{definition}->{$ovalid}->{metadata}->{advisory}->{rights}) ) {
          $erratainfo{'notes'}  = "The description and CVE numbers has been taken from Red Hat OVAL definitions.\n\n";
          $erratainfo{'notes'} .= $rhsaxml->{definitions}->{definition}->{$ovalid}->{metadata}->{advisory}->{rights};
        }
      }

      # Create an array of CVEs from Red Hat OVAL file to add to Errata later
      if ( ref($rhsaxml->{definitions}->{definition}->{$ovalid}->{metadata}->{reference}) eq 'ARRAY') {
        foreach $reference (@{$rhsaxml->{definitions}->{definition}->{$ovalid}->{metadata}->{reference}}) {
          if ($reference->{source} eq 'CVE') {
             push(@cves, $reference->{ref_id});
          }
        }
      }
 
    }

    if ($opt_get_from_rhn && !$opt_redhat) {
	# this only needs to be done for CentOS , not RedHat
        &set_proxy($opt_rhn_proxy);
        my $rhn_errata_details=&rhn_get_details($rhn_client,$rhn_session,$advid);
	# the Redhat API call returns errata_notes and such, spacewalk needs just "notes" and alike
	$erratainfo{'notes'}=$rhn_errata_details->{'errata_notes'};
	$erratainfo{'description'}=$rhn_errata_details->{'errata_description'};
	$erratainfo{'topic'}=$rhn_errata_details->{'errata_topic'};
	# let's replace the redhat references in the text
	$erratainfo{'notes'} =~ s/Red\s?Hat\s?Enterprise\s?Linux/CentOS/gs;
	$erratainfo{'description'} =~ s/Red\s?Hat\s?Enterprise\s?Linux/CentOS/gs;
	$erratainfo{'topic'} =~ s/Red\s?Hat\s?Enterprise\s?Linux/CentOS/gs;
        &set_proxy($opt_proxy);
    }

    my (@keywords,@bugs);
    if ($opt_get_from_rhn || $opt_redhat) {
	# for both CentOS and RedHat
        &set_proxy($opt_rhn_proxy);
        @keywords=&rhn_get_keywords($rhn_client,$rhn_session,$advid);
        @bugs=&rhn_get_bugs($rhn_client,$rhn_session,$advid,$opt_bugzilla_url);
        @cves=&rhn_get_cves($rhn_client,$rhn_session,$advid);
        &set_proxy($opt_proxy);
    }

    if (@packages >= 1) {
      # If there is at least one matching package in the errata
      &info("Creating errata $adv_name for $advid ($xml->{$advid}->{'synopsis'}) (All ".($#packages +1)." packages present in the corresponding channel)\n");
      if ($opt_publish) {
        eval {$result = $client->call('errata.create', $session, \%erratainfo, \@bugs, \@keywords, \@packages, $client->boolean(1), [ $opt_channel ]);}
      } else {
        eval {$result = $client->call('errata.create', $session, \%erratainfo, \@bugs, \@keywords, \@packages, $client->boolean(0), [ $opt_channel ]);}
      }
      if ($@) {
        &warning("An error occurred while creating the errata $advid\n");
        if ($@ =~ /unique constraint \(SPACEWALK_MAIN.RHN_CNP_CID_NID_UQ\) violated/) {
           &warning("Since it's a bogus 'unique constraint (SPACEWALK_MAIN.RHN_CNP_CID_NID_UQ) violated' error, we can safely ignore it.\n");
        } else {
           &warning("The error is $@\n");
        }
      }

      if (@cves >= 1) {
            &info("Adding CVE information to created $adv_name\n");
            &debug("CVEs in $advid: ".join(',', @cves)."\n");
            %erratadetails = ( "cves" => [ @cves ] );
            eval{$result = $client->call('errata.set_details', $session, $adv_name, \%erratadetails);}
      }

    } else {
      # There is no related package so there is no errata created
      &info("Skipping errata $advid ($xml->{$advid}->{'synopsis'}) -- No packages found\n");
    }

  } else {
    &info("Errata for $advid already exists\n");
  }
}

# FIN
$client->call('auth.logout', $session);
if ($opt_get_from_rhn) {
        &set_proxy($opt_rhn_proxy);
	$rhn_client->call('auth.logout', $rhn_session);
        &set_proxy($opt_proxy);
}

