package eventMacro::Condition::BaseLevel;

use strict;
use Settings;
use Globals;
use Log qw(message error warning debug);

use eventMacro::Condition;
use base qw(eventMacro::Condition);

use eventMacro::Data;
use eventMacro::Utilities qw(parse_syntax_condition_operator_plus_number_or_variable validate_code_number_operator_compare_number_or_variable);

sub new {
	my ($class, $condition_code) = @_;
	my $self = $class->SUPER::new();
	
	$self->{Name} = 'BaseLevel';
	$self->{Code_Level} = undef;
	$self->{Code_Operator} = undef;
	return undef unless ($self->parse_syntax($condition_code));
	
	$self->{is_Unique_Condition} = 0;
	$self->{Hooks} = ['packet/sendMapLoaded', 'packet/stat_info'];

	return $self;
}

sub validate_condition_status {
	my ($self, $event_name, $args) = @_;
	
	return if ($event_name eq 'packet/stat_info' && $args && $args->{type} != 11);
	
	$self->{is_Fulfilled} = validate_code_number_operator_compare_number_or_variable($char->{lv}, $self->{Code_Operator}, $self->{Code_Level}, (@{$self->{Variables}} > 0 ? 1 : 0));
}

sub parse_syntax {
	my ($self, $condition_code) = @_;
	unless ( parse_syntax_condition_operator_plus_number_or_variable($condition_code, \$self->{Code_Operator}, \$self->{Code_Level}, $self->{Variables}) ) {
		error "[eventMacro] Bad syntax in condition '".$self->get_name()."': '".$condition_code."'\n";
		return 0;
	}
	return 1;
}

1;