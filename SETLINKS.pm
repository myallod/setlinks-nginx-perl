=pod
 Код вызова ссылок SetLinks.ru.
 Версия 0.0.7 для nginx
 Вызов из SSI: <!--# perl sub="SHOWSETLINKS::SHOWLINKS" arg="string setlinks user" arg="string http host" arg="string request_uri" arg="string charset: UTF-8" arg="string debug: true|false" arg="number of links: 5" -->
=cut

package SLClient;
use strict;


our $VERSION = '0.0.7';



BEGIN {
	my @mods = (
		'File::Basename',
 		'IO::File',
 		'List::Util qw[min max]',
 		'IO::Socket',
 		'String::CRC32',
	);

	foreach my $mod (@mods) {
		unless (eval "use $mod; 1") {
			print "<!-- SetLinks Error: module not found: $mod -->\n";
		}
	}
}

sub new {
	my ($class, %args) = @_;

	my $config = \%args;
	$args{'aliases'} = {};
	$args{'server'} = 'show.setlinks.ru';
	$args{'cachetimeout'} = 600;
	$args{'errortimeout'} = 60;
	$args{'sockettimeout'} = 6;
	$args{'cachedir'} = '/tmp';
	$args{'indexfile'} = '^/index\\.(html|htm|php|phtml|asp|pl)$';

	my $self = {
		config => $config,
		uri => $args{'request_uri'},
		host => $args{'host'},
		links => undef,
		curlink => 0,
		servercachetime => 0,
		cachetime => 0,
		errortime => 0,
		delimiter => ''
	};

	bless $self, $class;

	$self->{uri} =~ s/&?\w+=[a-f\d]{32}//i;
	$self->{uri} =~ s/[&?]+$//;
	$self->{uri} =~ s/$self->{config}{indexfile}/\//;
	$self->{host} = substr($self->{host}, 0, 4) eq 'www.' ? substr($self->{host}, 4) : $self->{host};

	if(exists($self->{config}{aliases}{$self->{host}})) {
		$self->{host} = $self->{config}{aliases}{$self->{host}};
	}

	#add trailing slash at the cachedir
	$self->{config}{cachedir} =~ s!/*$!/!;

	if(not -e $self->{config}{cachedir} or not -d $self->{config}{cachedir}) {
		$self->_error("Can't open cache dir!");
	}
	elsif(not -w $self->{config}{cachedir}) {
		$self->_error("Cache dir: Permission denied!");
	}

	$self->{cachefile} = $self->{host}.'.'.$self->{config}{password}.'.setlinks';
	
	return $self;
}

sub saveLinksToCache {
	my ($self, $links, $info) = @_;

	if(scalar(@$info) != 4){return;}

	my @info2 = @$info[0,2,3];

	if(open(my $file, ">", $self->{config}{cachedir}.$self->{cachefile})) {
		$info2[3] = "0000000000";

		print $file time(),"\t",join("\t", @info2),"\n";
		foreach my $link (@$links) {
			print ($file  join("\t", @$link), "\n")  if (scalar(@$link) > 1);
		}
		close($file);
		return 1;
	}
	else {
		return $self->_error('Can\'t open cache file!');
	}
}

sub isCached {
	my $self = shift;
	if(-e $self->{config}{cachedir}.$self->{cachefile}) {
		if(open(my $file, '<', $self->{config}{cachedir}.$self->{cachefile})) {
			my $line = <$file>;
			chomp($line);
			close($file);
			my @info = split("\t", $line);
			$self->{cachetime} = min(time()+24*60*60, $info[0]);
			$self->{servercachetime} = $info[1];
			$self->{delimiter} = $info[2];
			$self->{errortime} = $info[4];
		}
	}
	return (($self->{cachetime} + $self->{config}{cachetimeout}) > time()) || (($self->{errortime} + $self->{config}{errortimeout}) > time());
}

sub getLinks {

	my $self = shift;
	my $countlinks = shift || 0;
	my $delimiter = shift || undef;

	if(!$self->isCached()) {
		if(!$self->downloadLinks()) {
			if(-e $self->{config}{cachedir}.$self->{cachefile}) {
				if(open(my $file, '+<',$self->{config}{cachedir}.$self->{cachefile})) {
					my $line = <$file>;
					if(length($line) > 25) {
						seek($file, length($line)-11, SEEK_SET);
						print $file time();
					}
					close($file);
				}
			}
		}
	}

	my $pageid = crc32($self->{host} . $self->{uri});

	if(!$self->{links}) {
		if(open(my $file, '<', $self->{config}{cachedir}.$self->{cachefile})) {
			my $line = <$file>;
			chomp($line);
			my @info = split("\t", $line);
			$self->{servercachetime} = $info[0];
			$self->{cachetime} = $info[1];
			$self->{delimiter} = $info[2];
			$self->{links} = [];
			while($line = <$file>) {
				my @links = split("\t", $line);
				if($links[0] == $pageid) {
					shift @links;
					$self->{links} = [@links];
				}
			}
			close($file);
		}
	}
	my @returnlinks = ();
	my $cnt = $self->{links} ? scalar(@{$self->{links}}) : 0;

	if ($countlinks > 0) {
		$cnt = min($cnt, $self->{curlink}+$countlinks);
	}

	for(; $self->{curlink} < $cnt; $self->{curlink}++) {
		push(@returnlinks, $self->{links}[$self->{curlink}]);
	}

	my $retstring = '<!--'.substr($self->{config}{password}, 0, 5).'-->' ;

	if(not defined $delimiter) {
		$delimiter = $self->{delimiter};
	}

	$retstring .= join($delimiter, @returnlinks);

	return $retstring;
}

sub downloadLinks {
	my $self = shift;
	my $page = '';
	my $path = "/?host=".$self->{host}."&k=".$self->{config}{encoding}."&p=".$self->{config}{password};

	my $remote = IO::Socket::INET->new(
		PeerAddr => $self->{config}{server},
		PeerPort => 80,
		Proto 	 => "tcp",
		Type 	 => SOCK_STREAM,
		Timeout  => $self->{config}{sockettimeout}
	) or return $self->_error('Error occured due fetching links from server');

	$remote->autoflush(1);
	print $remote "GET $path HTTP/1.0\r\nHost: ".$self->{config}{server}."\r\nConnection: Close\r\n\r\n";
	while ( <$remote> ) { $page .= $_; }
	close $remote;

	unless($page =~ m@^HTTP/\d+\.\d+\s+200\s@){ return $self->_error('Error server answer');}
	return $self->saveLinks($page);
}

sub saveLinks {
	my($self, $page) = @_;
	my ($headers, $body) = split("\r\n\r\n", $page, 2);

	unless($body) {return $self->_error('Incorrect answer from server');}

	if (length($body) < 20) {
		return 0;
	}

	my($info, $links_txt) = split("\n", $body, 2);
	my @sys_info = split("\t", $info);
	unless ($self->{config}{password} eq $sys_info[1]) {return $self->_error('Incorrect password!');}

	$self->{servercachetime} = $sys_info[0];
	$self->{cachetime} = time();
	$self->{delimiter} = $sys_info[2];
	$self->{errortime} = 0;

	my @linksn = split("\n", $links_txt);

	my @links = ();

	foreach my $val (@linksn) {
		my @t = split("\t", $val);
		push(@links, \@t);
	}

	unless ($self->saveLinksToCache(\@links, \@sys_info)) {return $self->_error('Can\'t write cache!');}
	return 1;
}


sub setCursorPosition {
	my($self, $position) = @_;
	$self->{curlink} = max(int($position) - 1, 0);
}

sub _error {
	my ($self, $err) = @_;
	if($self->{config}{debug} eq 'yes') {
		print "<font color=\"red\">SetLinks error: $err </font><br>\n";
	}
	return 0;
}

################################################################################

package SHOWSETLINKS;
use strict;
use base qw(SLClient);

sub SHOWLINKS {
	my $r = shift;
	(my $password, my $host, my $request_uri, my $encoding, my $debug, my $count) = @_;
	$r->send_http_header("text/html");
	my $setlinks = new SLClient(
		'password'	=> $password,
		'host'		=> $host || $r->variable('server_name'),
		'request_uri'	=> $request_uri || $r->variable('request_uri'),
		'encoding'	=> $encoding,
		'debug'		=> $debug,
	);
	$count ||= 10;
	$r->status(200);
	$r->print($setlinks->getLinks($count, '</li><li>'));
	return "OK";
}

1;
