package eventMacro::Core;

use strict;
use Globals;
use Log qw(message error warning debug);
use Utils;
use AI;

use eventMacro::Core;
use eventMacro::Data;
use eventMacro::Lists;
use eventMacro::Automacro;
use eventMacro::FileParser;
use eventMacro::Macro;
use eventMacro::Runner;
use eventMacro::Condition;

sub new {
	my ($class, $file) = @_;
	my $self = bless {}, $class;
	
	my $parse_result = parseMacroFile($file, 0);
	return undef unless ($parse_result);
	
	$self->{Macro_List} = new eventMacro::Lists;
	$self->create_macro_list($parse_result->{macros});
	
	$self->{Automacro_List} = new eventMacro::Lists;
	$self->{Condition_Modules_Loaded} = {};
	$self->create_automacro_list($parse_result->{automacros});
	
	$self->{automacros_index_to_AI_check_state} = {};
	$self->define_automacro_check_state;
	
	$self->{AI_start_Macros_Running_Hook_Handle} = undef;
	$self->{AI_start_Automacros_Check_Hook_Handle} = undef;
	$self->set_automacro_checking_status();
	
	$self->{Event_Related_Scalar_Variables} = {};
	$self->{Event_Related_Array_Variables} = {};
	$self->{Event_Related_Accessed_Array_Variables} = {};
	$self->{Event_Related_Hash_Variables} = {};
	$self->{Event_Related_Accessed_Hash_Variables} = {};
	
	$self->{Event_Related_Hooks} = {};
	$self->{Hook_Handles} = {};
	$self->create_callbacks();
	
	$self->{Macro_Runner} = undef;
	
	$self->{Scalar_Variable_List_Hash} = {};
	$self->{Array_Variable_List_Hash} = {};
	$self->{Hash_Variable_List_Hash} = {};
	
	$self->{number_of_triggered_automacros} = 0;
	
	#must add a sorting algorithm here later
	$self->{triggered_prioritized_automacros_index_list} = [];
	
	$self->{automacro_index_to_queue_index} = {};
	
	$self->set_arrays_size_to_zero();
	$self->set_hashes_size_to_zero();
	
	if ($char && $net && $net->getState() == Network::IN_GAME) {
		$self->check_all_conditions();
	}
	
	return $self;
}

sub unload {
	my ($self) = @_;
	$self->clear_queue();
	$self->clean_hooks();
	Plugins::delHook($self->{AI_start_Automacros_Check_Hook_Handle}) if ($self->{AI_start_Automacros_Check_Hook_Handle});
}

sub clean_hooks {
	my ($self) = @_;
	foreach (values %{$self->{Hook_Handles}}) {Plugins::delHook($_)}
}

sub set_automacro_checking_status {
	my ($self, $status) = @_;
	
	if (!defined $self->{Automacros_Checking_Status}) {
		debug "[eventMacro] Initializing automacro checking by default.\n", "eventMacro", 2;
		$self->{Automacros_Checking_Status} = CHECKING_AUTOMACROS;
		$self->{AI_start_Automacros_Check_Hook_Handle} = Plugins::addHook( 'AI_start', sub { my $state = $_[1]->{state}; $self->AI_start_checker($state); }, undef );
		return;
	} elsif ($self->{Automacros_Checking_Status} == $status) {
		debug "[eventMacro] automacro checking status is already $status.\n", "eventMacro", 2;
	} else {
		debug "[eventMacro] Changing automacro checking status from '".$self->{Automacros_Checking_Status}."' to '".$status."'.\n", "eventMacro", 2;
		if (
		  ($self->{Automacros_Checking_Status} == CHECKING_AUTOMACROS || $self->{Automacros_Checking_Status} == CHECKING_FORCED_BY_USER) &&
		  ($status == PAUSED_BY_EXCLUSIVE_MACRO || $status == PAUSE_FORCED_BY_USER)
		) {
			if (defined $self->{AI_start_Automacros_Check_Hook_Handle}) {
				debug "[eventMacro] Deleting AI_start hook.\n", "eventMacro", 2;
				Plugins::delHook($self->{AI_start_Automacros_Check_Hook_Handle});
				$self->{AI_start_Automacros_Check_Hook_Handle} = undef;
			} else {
				error "[eventMacro] Tried to delete AI_start hook and for some reason it is already undefined.\n";
			}
		} elsif (
		  ($self->{Automacros_Checking_Status} == PAUSED_BY_EXCLUSIVE_MACRO || $self->{Automacros_Checking_Status} == PAUSE_FORCED_BY_USER) &&
		  ($status == CHECKING_AUTOMACROS || $status == CHECKING_FORCED_BY_USER)
		) {
			if (defined $self->{AI_start_Automacros_Check_Hook_Handle}) {
				error "[eventMacro] Tried to add AI_start hook and for some reason it is already defined.\n";
			} else {
				debug "[eventMacro] Adding AI_start hook.\n", "eventMacro", 2;
				$self->{AI_start_Automacros_Check_Hook_Handle} = Plugins::addHook( 'AI_start',  sub { my $state = $_[1]->{state}; $self->AI_start_checker($state); }, undef );
			}
		}
		$self->{Automacros_Checking_Status} = $status;
	}
}

sub get_automacro_checking_status {
	my ($self) = @_;
	return $self->{Automacros_Checking_Status};
}

sub create_macro_list {
	my ($self, $macro) = @_;
	while (my ($name,$lines) = each %{$macro}) {
		my $currentMacro = new eventMacro::Macro($name, $lines);
		$self->{Macro_List}->add($currentMacro);
	}
}

sub create_automacro_list {
	my ($self, $automacro) = @_;
	my %modulesLoaded;
	AUTOMACRO: while (my ($name,$value) = each %{$automacro}) {
		my ($currentAutomacro, %currentConditions, %currentParameters, $has_event_type_condition, $event_type_condition_name);
		$has_event_type_condition = 0;
		$event_type_condition_name = undef;
		
		####################################
		#####No Conditions Check
		####################################
		if (!exists $value->{'conditions'} || !@{$value->{'conditions'}}) {
			error "[eventMacro] Ignoring automacro '$name'. There are no conditions set it in\n";
			next AUTOMACRO;
		}
	
		####################################
		#####No Parameters Check
		####################################
		if (!exists $value->{'parameters'} || !@{$value->{'parameters'}}) {
			error "[eventMacro] Ignoring automacro '$name'. There are no parameters set in it\n";
			next AUTOMACRO;
		}
		
		PARAMETER: foreach my $parameter (@{$value->{'parameters'}}) {
		
			###Check Duplicate Parameter
			if (exists $currentParameters{$parameter->{'key'}}) {
				warning "[eventMacro] Ignoring automacro '$name' (parameter ".$parameter->{'key'}." duplicate)\n";
				next AUTOMACRO;
			}
			###Parameter: call
			if ($parameter->{'key'} eq "call" && !$self->{Macro_List}->getByName($parameter->{'value'})) {
				warning "[eventMacro] Ignoring automacro '$name' (call '".$parameter->{'value'}."' is not a valid macro name)\n";
				next AUTOMACRO;
			
			###Parameter: delay
			} elsif ($parameter->{'key'} eq "delay" && $parameter->{'value'} !~ /\d+/) {
				error "[eventMacro] Ignoring automacro '$name' (delay parameter should be a number)\n";
				next AUTOMACRO;
			
			###Parameter: run-once
			} elsif ($parameter->{'key'} eq "run-once" && $parameter->{'value'} !~ /[01]/) {
				error "[eventMacro] Ignoring automacro '$name' (run-once parameter should be '0' or '1')\n";
				next AUTOMACRO;
			
			###Parameter: CheckOnAI
			} elsif ($parameter->{'key'} eq "CheckOnAI" && $parameter->{'value'} !~ /^(auto|off|manual)(\s*,\s*(auto|off|manual))*$/) {
				error "[eventMacro] Ignoring automacro '$name' (CheckOnAI parameter should be a list containing only the values 'auto', 'manual' and 'off')\n";
				next AUTOMACRO;
			
			###Parameter: disabled
			} elsif ($parameter->{'key'} eq "disabled" && $parameter->{'value'} !~ /[01]/) {
				error "[eventMacro] Ignoring automacro '$name' (disabled parameter should be '0' or '1')\n";
				next AUTOMACRO;
			
			###Parameter: overrideAI
			} elsif ($parameter->{'key'} eq "overrideAI" && $parameter->{'value'} !~ /[01]/) {
				error "[eventMacro] Ignoring automacro '$name' (overrideAI parameter should be '0' or '1')\n";
				next AUTOMACRO;
			
			###Parameter: exclusive
			} elsif ($parameter->{'key'} eq "exclusive" && $parameter->{'value'} !~ /[01]/) {
				error "[eventMacro] Ignoring automacro '$name' (exclusive parameter should be '0' or '1')\n";
				next AUTOMACRO;
			
			###Parameter: priority
			} elsif ($parameter->{'key'} eq "priority" && $parameter->{'value'} !~ /\d+/) {
				error "[eventMacro] Ignoring automacro '$name' (priority parameter should be a number)\n";
				next AUTOMACRO;
			
			###Parameter: macro_delay
			} elsif ($parameter->{'key'} eq "macro_delay" && $parameter->{'value'} !~ /(\d+|\d+\.\d+)/) {
				error "[eventMacro] Ignoring automacro '$name' (macro_delay parameter should be a number (decimals are accepted))\n";
				next AUTOMACRO;
			
			###Parameter: orphan
			} elsif ($parameter->{'key'} eq "orphan" && $parameter->{'value'} !~ /(terminate|terminate_last_call|reregister|reregister_safe)/) {
				error "[eventMacro] Ignoring automacro '$name' (orphan parameter should be 'terminate', 'terminate_last_call', 'reregister' or 'reregister_safe')\n";
				next AUTOMACRO;
			###Parameter: repeat
			} elsif ($parameter->{'key'} eq "repeat" && $parameter->{'value'} !~ /\d+/) {
				error "[eventMacro] Ignoring automacro '$name' (repeat parameter should be a number)\n";
				next AUTOMACRO;
			} else {
				$currentParameters{$parameter->{'key'}} = $parameter->{'value'};
			}
		}
		
		###Recheck Parameter call
		if (!exists $currentParameters{'call'}) {
			warning "[eventMacro] Ignoring automacro '$name' (all automacros must have a macro call)\n";
			next AUTOMACRO;
		}
		
		####################################
		#####Conditions Check
		####################################
		CONDITION: foreach my $condition (@{$value->{'conditions'}}) {
		
			my ($condition_object, $condition_module);
			
			$condition_module = "eventMacro::Condition::".$condition->{'key'};
			
			if (!exists $self->{Condition_Modules_Loaded}{$condition_module}) {
				unless ($self->load_condition_module($condition_module)) {
					warning "[eventMacro] Ignoring automacro '".$name."' (could not load condition module)\n";
					next AUTOMACRO;
				}
			}
			
			$condition_object = $condition_module->new($condition->{'value'});
			
			if (defined $condition_object->error) {
				warning "[eventMacro] Ignoring automacro '".$name."'\n".
				        "[eventMacro] Error in condition '".$condition->{'key'}."'\n".
				        "[eventMacro] Error type: Wrong condition syntax ('".$condition->{'value'}."')\n".
				        "[eventMacro] Error code: '".$condition_object->error."'.\n";
				next AUTOMACRO;
			}
			
			if (exists $currentConditions{$condition_module} && $condition_object->is_unique_condition()) {
				error "[eventMacro] Condition '".$condition->{'key'}."' cannot be used more than once in an automacro. It was used twice (or more) in automacro '".$name."'\n";
				warning "[eventMacro] Ignoring automacro '$name' (multiple unique condition)\n";
				next AUTOMACRO;
			}
			
			if ($condition_object->condition_type == EVENT_TYPE) {
				if ($has_event_type_condition) {
					error "[eventMacro] Conditions '".$condition->{'key'}."' and '".$event_type_condition_name."' are of the event type and can only be used once per automacro.\n";
					warning "[eventMacro] Ignoring automacro '$name' (multiple event type conditions)\n";
					next AUTOMACRO;
				} else {
					$has_event_type_condition = 1;
					$event_type_condition_name = $condition->{'key'};
				}
			}
			
			push( @{ $currentConditions{$condition_module} }, $condition->{'value'} );
			
		}
		
		####################################
		#####Automacro Object Creation
		####################################
		$currentAutomacro = new eventMacro::Automacro($name, \%currentParameters);
		my $new_index = $self->{Automacro_List}->add($currentAutomacro);
		$self->{Automacro_List}->get($new_index)->parse_and_create_conditions(\%currentConditions);
	}
}

sub load_condition_module {
	my ($self, $condition_module) = @_;
	undef $@;
	debug "[eventMacro] Loading module '".$condition_module."'\n", "eventMacro", 2;
	eval "use $condition_module";
	if ($@ =~ /^Can't locate /s) {
		FileNotFoundException->throw("Cannot locate automacro module ".$condition_module.".");
	} elsif ($@) {
		ModuleLoadException->throw("An error occured while loading condition module ".$condition_module.":".$@.".");
	} else {
		$self->{Condition_Modules_Loaded}{$condition_module} = 1;
	}
}

sub define_automacro_check_state {
	my ($self) = @_;
	foreach my $automacro (@{$self->{Automacro_List}->getItems()}) {
		my $automacro_index = $automacro->get_index;
		my $parameter = $automacro->{check_on_ai_state};
		$self->{automacros_index_to_AI_check_state}{$automacro_index}{AI::OFF} = exists $parameter->{'off'} ? 1 : 0;
		$self->{automacros_index_to_AI_check_state}{$automacro_index}{AI::MANUAL} = exists $parameter->{'manual'} ? 1 : 0;
		$self->{automacros_index_to_AI_check_state}{$automacro_index}{AI::AUTO} = exists $parameter->{'auto'} ? 1 : 0;
	}
}

sub create_callbacks {
	my ($self) = @_;
	
	debug "[eventMacro] create_callback called\n", "eventMacro", 2;
	
	foreach my $automacro (@{$self->{Automacro_List}->getItems()}) {
	
		debug "[eventMacro] Creating callback for automacro '".$automacro->get_name()."'\n", "eventMacro", 2;
		
		my $automacro_index = $automacro->get_index;
		
		# Hooks
		foreach my $hook_name ( keys %{ $automacro->get_hooks() } ) {
			my $conditions_indexes = $automacro->{hooks}->{$hook_name};
			foreach my $condition_index (@{$conditions_indexes}) {
				$self->{Event_Related_Hooks}{$hook_name}{$automacro_index}{$condition_index} = 1;
			}
			
		}
		
		# Scalars
		foreach my $var ( keys %{ $automacro->get_scalar_variables } ) {
			my $conditions_indexes = $automacro->{scalar_variables}->{$var};
			foreach my $condition_index (@{$conditions_indexes}) {
				$self->{Event_Related_Scalar_Variables}{$var}{$automacro_index}{$condition_index} = 1;
			}
		}
		
		# Arrays
		foreach my $var ( keys %{ $automacro->get_array_variables } ) {
			my $conditions_indexes = $automacro->{array_variables}->{$var};
			foreach my $condition_index (@{$conditions_indexes}) {
				$self->{Event_Related_Array_Variables}{$var}{$automacro_index}{$condition_index} = 1;
			}
		}
		
		# Accessed arrays
		foreach my $var ( keys %{ $automacro->get_accessed_array_variables } ) {
			my $array = $automacro->{accessed_array_variables}->{$var};
			foreach my $array_index (0..$#{$array}) {
				my $cond_indexes = $array->[$array_index];
				next unless (defined $cond_indexes);
				foreach my $condition_index (@{$cond_indexes}) {
					$self->{Event_Related_Accessed_Array_Variables}{$var}{$array_index}{$automacro_index}{$condition_index} = 1;
				}
			}
		}
		
		# Hashes
		foreach my $var ( keys %{ $automacro->get_hash_variables } ) {
			my $conditions_indexes = $automacro->{hash_variables}->{$var};
			foreach my $condition_index (@{$conditions_indexes}) {
				$self->{Event_Related_Hash_Variables}{$var}{$automacro_index}{$condition_index} = 1;
			}
		}
		
		# Accessed hashes
		foreach my $var ( keys %{ $automacro->get_accessed_hash_variables } ) {
			my $hash = $automacro->{accessed_hash_variables}->{$var};
			foreach my $hash_key (keys %{$hash}) {
				my $cond_indexes = $hash->{$hash_key};
				next unless (defined $cond_indexes);
				foreach my $condition_index (@{$cond_indexes}) {
					$self->{Event_Related_Accessed_Hash_Variables}{$var}{$hash_key}{$automacro_index}{$condition_index} = 1;
				}
			}
		}
		
	}
	
	my $event_sub = sub { $self->manage_event_callbacks('hook', shift, shift); };
	foreach my $hook_name (keys %{$self->{Event_Related_Hooks}}) {
		$self->{Hook_Handles}{$hook_name} = Plugins::addHook( $hook_name, $event_sub, undef );
	}
}

sub set_arrays_size_to_zero {
	my ($self) = @_;
	foreach my $array_name (keys %{$self->{Event_Related_Array_Variables}}) {
		$self->array_size_change($array_name);
	}
}

sub set_hashes_size_to_zero {
	my ($self) = @_;
	foreach my $hash_name (keys %{$self->{Event_Related_Hash_Variables}}) {
		$self->hash_size_change($hash_name);
	}
}

sub check_all_conditions {
	my ($self) = @_;
	debug "[eventMacro] Starting to check all state type conditions\n", "eventMacro", 2;
	my @automacros = @{ $self->{Automacro_List}->getItems() };
	foreach my $automacro (@automacros) {
		debug "[eventMacro] Checking all state type conditions in automacro '".$automacro->get_name."'\n", "eventMacro", 2;
		my @conditions = @{ $automacro->{conditionList}->getItems() };
		foreach my $condition (@conditions) {
			next if ($condition->condition_type == EVENT_TYPE);
			debug "[eventMacro] Checking condition of index '".$condition->get_index."' in automacro '".$automacro->get_name."'\n", "eventMacro", 2;
			$automacro->check_state_type_condition($condition->get_index, 'recheck')
		}
		if ($automacro->can_be_added_to_queue) {
			$self->add_to_triggered_prioritized_automacros_index_list($automacro);
		}
	}
}

# Generic variable functions
sub get_var {
	my ($self, $type, $variable_name, $complement) = @_;
	
	if ($type eq 'scalar') {
		return ($self->get_scalar_var($variable_name));
		
	} elsif ($type eq 'accessed_array') {
		return ($self->get_array_var($variable_name, $complement));
		
	} elsif ($type eq 'accessed_hash') {
		return ($self->get_hash_var($variable_name, $complement));
		
	} else {
		error "[eventMacro] You can't call get_var with a variable type other than 'scalar', 'accessed_array' or 'accessed_hash'.\n";
		return undef;
	}
}

sub set_var {
	my ($self, $type, $variable_name, $variable_value, $check_callbacks, $complement) = @_;
	
	if ($type eq 'scalar') {
		return ($self->set_scalar_var($variable_name, $variable_value, $check_callbacks));
		
	} elsif ($type eq 'accessed_array') {
		return ($self->set_array_var($variable_name, $complement, $variable_value, $check_callbacks));
		
	} elsif ($type eq 'accessed_hash') {
		return ($self->set_hash_var($variable_name, $complement, $variable_value, $check_callbacks));
		
	} else {
		error "[eventMacro] You can't call set_var with a variable type other than 'scalar', 'accessed_array' or 'accessed_hash'.\n";
		return undef;
	}
}

sub defined_var {
	my ($self, $type, $variable_name, $complement) = @_;
	
	if ($type eq 'scalar') {
		return ($self->is_scalar_var_defined($variable_name));
		
	} elsif ($type eq 'accessed_array') {
		return ($self->is_array_var_defined($variable_name, $complement));
		
	} elsif ($type eq 'accessed_hash') {
		return ($self->is_hash_var_defined($variable_name, $complement));
		
	} else {
		error "[eventMacro] You can't call defined_var with a variable type other than 'scalar', 'accessed_array' or 'accessed_hash'.\n";
		return undef;
	}
}

# Scalars
sub get_scalar_var {
	my ($self, $variable_name) = @_;
	return $self->{Scalar_Variable_List_Hash}{$variable_name} if (exists $self->{Scalar_Variable_List_Hash}{$variable_name});
	return undef;
}

sub set_scalar_var {
	my ($self, $variable_name, $variable_value, $check_callbacks) = @_;
	if ($variable_value eq 'undef') {
		undef $variable_value;
		$self->{Scalar_Variable_List_Hash}{$variable_name} = undef;
	} else {
		$self->{Scalar_Variable_List_Hash}{$variable_name} = $variable_value;
	}
	return if (defined $check_callbacks && $check_callbacks == 0);
	$self->check_necessity_and_callback('scalar', $variable_name, $variable_value);
}

sub is_scalar_var_defined {
	my ($self, $variable_name) = @_;
	return ((defined $self->{Scalar_Variable_List_Hash}{$variable_name}) ? 1 : 0);
}
#########

# Arrays
sub set_full_array {
	my ($self, $variable_name, $list) = @_;
	
	my @old_array = (exists $self->{Array_Variable_List_Hash}{$variable_name} ? (@{$self->{Array_Variable_List_Hash}{$variable_name}}) : ([]));
	my $old_last_index = $#old_array;
	my $new_last_index = $#{$list};
	
	debug "[eventMacro] Setting array '@".$variable_name."'\n", "eventMacro";
	foreach my $member_index (0..$new_last_index) {
		my $member = $list->[$member_index];
		$self->{Array_Variable_List_Hash}{$variable_name}[$member_index] = $member;
		$self->check_necessity_and_callback('accessed_array', $variable_name, $member, $member_index);
	}
	if ($new_last_index < $old_last_index) {
		splice(@{$self->{Array_Variable_List_Hash}{$variable_name}}, ($new_last_index+1));
		if (exists $self->{Event_Related_Accessed_Array_Variables}{$variable_name}) {
			foreach my $old_member_index (($new_last_index+1)..$old_last_index) {
				$self->check_necessity_and_callback('accessed_array', $variable_name, undef, $old_member_index);
			}
		}
	}
	$self->array_size_change($variable_name) if ($new_last_index != $old_last_index);
}

sub clear_array {
	my ($self, $variable_name) = @_;
	if (exists $self->{Array_Variable_List_Hash}{$variable_name}) {
		debug "[eventMacro] Clearing array '@".$variable_name."'\n", "eventMacro";
		my @old_array = @{$self->{Array_Variable_List_Hash}{$variable_name}};
		delete $self->{Array_Variable_List_Hash}{$variable_name};
		if (exists $self->{Event_Related_Accessed_Array_Variables}{$variable_name}) {
			foreach my $old_member_index (0..$#old_array) {
				$self->check_necessity_and_callback('accessed_array', $variable_name, undef, $old_member_index);
			}
		}
		$self->array_size_change($variable_name);
	}
}

sub push_array {
	my ($self, $variable_name, $new_member) = @_;
	
	push(@{$self->{Array_Variable_List_Hash}{$variable_name}}, $new_member);
	my $index = $#{$self->{Array_Variable_List_Hash}{$variable_name}};
	
	debug "[eventMacro] 'push' was used in array '@".$variable_name."' to add list member '".$new_member."' into position '".$index."'\n", "eventMacro";
	
	$self->check_necessity_and_callback('accessed_array', $variable_name, $new_member, $index);
	$self->array_size_change($variable_name);
	
	return (scalar @{$self->{Array_Variable_List_Hash}{$variable_name}});
}

sub unshift_array {
	my ($self, $variable_name, $new_member) = @_;
	
	my @old_array = @{$self->{Array_Variable_List_Hash}{$variable_name}};
	unshift(@{$self->{Array_Variable_List_Hash}{$variable_name}}, $new_member);
	my $index = $#{$self->{Array_Variable_List_Hash}{$variable_name}};
	
	debug "[eventMacro] 'unshift' was used in array '@".$variable_name."' to add list member '".$new_member."' into position '0'\n", "eventMacro";
	
	foreach my $member_index (0..$index) {
		my $member = ${$self->{Array_Variable_List_Hash}{$variable_name}}[$member_index];
		$self->check_necessity_and_callback('accessed_array', $variable_name, $member, $member_index);
	}
	$self->array_size_change($variable_name);
	
	return (scalar @{$self->{Array_Variable_List_Hash}{$variable_name}});
}

sub pop_array {
	my ($self, $variable_name) = @_;
	
	return unless (exists $self->{Array_Variable_List_Hash}{$variable_name});
	return unless (scalar @{$self->{Array_Variable_List_Hash}{$variable_name}} > 0);
	
	my $index = $#{$self->{Array_Variable_List_Hash}{$variable_name}};
	my $poped = pop(@{$self->{Array_Variable_List_Hash}{$variable_name}});
	
	debug "[eventMacro] 'pop' was used in array '@".$variable_name."' to remove member '".$poped."' from position '".$index."'\n", "eventMacro";
	
	
	$self->check_necessity_and_callback('accessed_array', $variable_name, undef, $index);
	$self->array_size_change($variable_name);
	
	return $poped;
}

sub shift_array {
	my ($self, $variable_name) = @_;
	
	return unless (exists $self->{Array_Variable_List_Hash}{$variable_name});
	return unless (scalar @{$self->{Array_Variable_List_Hash}{$variable_name}} > 0);
	
	my $index = $#{$self->{Array_Variable_List_Hash}{$variable_name}};
	my @old_array = @{$self->{Array_Variable_List_Hash}{$variable_name}};
	my $shifted = shift(@{$self->{Array_Variable_List_Hash}{$variable_name}});
	
	debug "[eventMacro] 'shift' was used in array '@".$variable_name."' to remove member '".$shifted."' from position '0'\n", "eventMacro";
	
	foreach my $member_index (0..$#{$self->{Array_Variable_List_Hash}{$variable_name}}) {
		my $member = ${$self->{Array_Variable_List_Hash}{$variable_name}}[$member_index];
		$self->check_necessity_and_callback('accessed_array', $variable_name, $member, $member_index);
	}
	
	$self->check_necessity_and_callback('accessed_array', $variable_name, undef, $index);
	$self->array_size_change($variable_name);
	
	return $shifted;
}

sub get_array_var {
	my ($self, $variable_name, $index) = @_;
	return $self->{Array_Variable_List_Hash}{$variable_name}[$index] if (exists $self->{Array_Variable_List_Hash}{$variable_name} && defined $self->{Array_Variable_List_Hash}{$variable_name}[$index]);
	return undef;
}

sub set_array_var {
	my ($self, $variable_name, $index, $variable_value, $check_callbacks) = @_;
	if ($variable_value eq 'undef') {
		undef $variable_value;
		$self->{Array_Variable_List_Hash}{$variable_name}[$index] = undef;
	} else {
		$self->{Array_Variable_List_Hash}{$variable_name}[$index] = $variable_value;
	}
	return if (defined $check_callbacks && $check_callbacks == 0);
	$self->check_necessity_and_callback('accessed_array', $variable_name, $variable_value, $index);
	$self->array_size_change($variable_name);
}

sub array_size_change {
	my ($self, $variable_name) = @_;
	my $size = ((exists $self->{Array_Variable_List_Hash}{$variable_name}) ? (scalar @{$self->{Array_Variable_List_Hash}{$variable_name}}) : 0);
	debug "[eventMacro] Size of array '@".$variable_name."' change to '".$size."'\n", "eventMacro";
	
	$self->check_necessity_and_callback('array', $variable_name, $size);
}

sub get_array_size {
	my ($self, $variable_name) = @_;
	if (exists $self->{Array_Variable_List_Hash}{$variable_name}) {
		return (scalar @{$self->{Array_Variable_List_Hash}{$variable_name}});
	}
	return 0;
}

sub is_array_var_defined {
	my ($self, $variable_name, $index) = @_;
	return ((exists $self->{Array_Variable_List_Hash}{$variable_name} && defined $self->{Array_Variable_List_Hash}{$variable_name}[$index]) ? 1 : 0);
}
#######

# Hahes
sub set_full_hash {
	my ($self, $variable_name, $hash) = @_;
	
	my %old_hash = (exists $self->{Hash_Variable_List_Hash}{$variable_name} ? (%{$self->{Hash_Variable_List_Hash}{$variable_name}}) : ({}));
	
	debug "[eventMacro] Setting hash '%".$variable_name."'\n", "eventMacro";
	foreach my $member_key (keys %{$hash}) {
		my $member = $hash->{$member_key};
		$self->{Hash_Variable_List_Hash}{$variable_name}{$member_key} = $member;
		$self->check_necessity_and_callback('accessed_hash', $variable_name, $member, $member_key);
	}
	if (exists $self->{Event_Related_Accessed_Hash_Variables}{$variable_name}) {
	
		foreach my $old_member_key (keys %old_hash) {
			if (!exists $self->{Hash_Variable_List_Hash}{$variable_name}{$old_member_key}) {
				$self->check_necessity_and_callback('accessed_hash', $variable_name, undef, $old_member_key);
			}
		}
		
	}
	$self->hash_size_change($variable_name) if ((scalar keys %old_hash) != (scalar keys %{$self->{Hash_Variable_List_Hash}{$variable_name}}));
}

sub clear_hash {
	my ($self, $variable_name) = @_;
	if (exists $self->{Hash_Variable_List_Hash}{$variable_name}) {
		debug "[eventMacro] Clearing hash '%".$variable_name."'\n", "eventMacro";
		my %old_hash = %{$self->{Hash_Variable_List_Hash}{$variable_name}};
		delete $self->{Hash_Variable_List_Hash}{$variable_name};
		if (exists $self->{Event_Related_Accessed_Hash_Variables}{$variable_name}) {
			foreach my $old_member_key (keys %old_hash) {
				$self->check_necessity_and_callback('accessed_hash', $variable_name, undef, $old_member_key);
			}
		}
		$self->hash_size_change($variable_name);
	}
}

sub get_hash_keys {
	my ($self, $variable_name) = @_;
	my %hash = (exists $self->{Hash_Variable_List_Hash}{$variable_name} ? (%{$self->{Hash_Variable_List_Hash}{$variable_name}}) : ({}));
	my @keys = keys %hash;
	return \@keys;
}

sub get_hash_values {
	my ($self, $variable_name) = @_;
	my %hash = (exists $self->{Hash_Variable_List_Hash}{$variable_name} ? (%{$self->{Hash_Variable_List_Hash}{$variable_name}}) : ({}));
	my @values = values %hash;
	return \@values;
}

sub exists_hash {
	my ($self, $variable_name, $key) = @_;
	if (exists $self->{Hash_Variable_List_Hash}{$variable_name} && exists $self->{Hash_Variable_List_Hash}{$variable_name}{$key}) {
		return 1;
	}
	return 0;
}

sub delete_key {
	my ($self, $variable_name, $key) = @_;
	if (exists $self->{Hash_Variable_List_Hash}{$variable_name} && exists $self->{Hash_Variable_List_Hash}{$variable_name}{$key}) {
		my $deleted = delete $self->{Hash_Variable_List_Hash}{$variable_name}{$key};
		return $deleted;
	}
}

sub get_hash_var {
	my ($self, $variable_name, $key) = @_;
	return $self->{Hash_Variable_List_Hash}{$variable_name}{$key} if (exists $self->{Hash_Variable_List_Hash}{$variable_name} && exists $self->{Hash_Variable_List_Hash}{$variable_name}{$key});
	return undef;
}

sub set_hash_var {
	my ($self, $variable_name, $key, $variable_value, $check_callbacks) = @_;
	if ($variable_value eq 'undef') {
		undef $variable_value;
		$self->{Hash_Variable_List_Hash}{$variable_name}{$key} = undef;
	} else {
		$self->{Hash_Variable_List_Hash}{$variable_name}{$key} = $variable_value;
	}
	return if (defined $check_callbacks && $check_callbacks == 0);
	$self->check_necessity_and_callback('accessed_hash', $variable_name, $variable_value, $key);
	$self->hash_size_change($variable_name);
}

sub hash_size_change {
	my ($self, $variable_name) = @_;
	my $size = ((exists $self->{Hash_Variable_List_Hash}{$variable_name}) ? (scalar keys %{$self->{Hash_Variable_List_Hash}{$variable_name}}) : 0);
	debug "[eventMacro] Size of hash '%".$variable_name."' change to '".$size."'\n", "eventMacro";
	
	$self->check_necessity_and_callback('hash', $variable_name, $size);
}

sub get_hash_size {
	my ($self, $variable_name) = @_;
	if (exists $self->{Hash_Variable_List_Hash}{$variable_name}) {
		return (scalar keys %{$self->{Hash_Variable_List_Hash}{$variable_name}});
	}
	return 0;
}

sub is_hash_var_defined {
	my ($self, $variable_name, $key) = @_;
	return ((exists $self->{Hash_Variable_List_Hash}{$variable_name} && exists $self->{Hash_Variable_List_Hash}{$variable_name}{$key} && defined $self->{Hash_Variable_List_Hash}{$variable_name}{$key}) ? 1 : 0);
}
########

sub check_necessity_and_callback {
	my ($self, $variable_type, $variable_name, $value, $complement) = @_;

	if ($variable_type eq 'scalar') {
		return unless (exists $self->{'Event_Related_Scalar_Variables'}{$variable_name});
		
	} elsif ($variable_type eq 'array') {
		return unless (exists $self->{'Event_Related_Array_Variables'}{$variable_name});
		
	} elsif ($variable_type eq 'accessed_array') {
		return unless (exists $self->{'Event_Related_Accessed_Array_Variables'}{$variable_name} && exists $self->{'Event_Related_Accessed_Array_Variables'}{$variable_name}{$complement});
		
	} elsif ($variable_type eq 'hash') {
		return unless (exists $self->{'Event_Related_Hash_Variables'}{$variable_name});
		
	} elsif ($variable_type eq 'accessed_hash') {
		return unless (exists $self->{'Event_Related_Accessed_Hash_Variables'}{$variable_name} && exists $self->{'Event_Related_Accessed_Hash_Variables'}{$variable_name}{$complement});
	}
	$self->manage_event_callbacks('variable', $variable_name, $value, $variable_type, $complement);
}

sub add_to_triggered_prioritized_automacros_index_list {
	my ($self, $automacro) = @_;
	my $priority = $automacro->get_parameter('priority');
	my $index = $automacro->get_index;
	
	my $list = $self->{triggered_prioritized_automacros_index_list} ||= [];
	
	my $index_hash = $self->{automacro_index_to_queue_index};

	# Find where we should insert this item.
	my $new_index;
	for ($new_index = 0 ; $new_index < @$list && @$list[$new_index]->{priority} <= $priority ; $new_index++) {}

	# Insert.
	splice @$list, $new_index, 0, { index => $index, priority => $priority };

	# Update indexes.
	foreach my $auto_index_in_queue ($new_index .. $#{$list}) {
		$index_hash->{$list->[$auto_index_in_queue]->{index}} = $auto_index_in_queue;
	}
	
	$self->{number_of_triggered_automacros}++;
	$automacro->running_status(1);

	debug "[eventMacro] Automacro '".$automacro->get_name()."' met it's conditions. Adding it to running queue in position '".$new_index."'.\n", "eventMacro";
	
	# Return the insertion index.
	return $new_index;
}

sub remove_from_triggered_prioritized_automacros_index_list {
	my ($self, $automacro) = @_;
	my $priority = $automacro->get_parameter('priority');
	my $index = $automacro->get_index;
	
	my $list = $self->{triggered_prioritized_automacros_index_list};
	
	my $index_hash = $self->{automacro_index_to_queue_index};
	
	# Find from where we should delete this item.
	my $queue_index = delete $index_hash->{$index};
	
	# remove.
	splice (@$list, $queue_index, 1);
	
	# Update indexes.
	foreach my $auto_index_in_queue ($queue_index .. $#{$list}) {
		$index_hash->{$list->[$auto_index_in_queue]->{index}} = $auto_index_in_queue;
	}
	
	$self->{number_of_triggered_automacros}--;
	$automacro->running_status(0);
	
	debug "[eventMacro] Automacro '".$automacro->get_name()."' no longer meets it's conditions. Removing it from running queue from position '".$queue_index."'.\n", "eventMacro";
	
	# Return the removal index.
	return $queue_index;
}

sub manage_event_callbacks {
	my $self = shift;
	my $callback_type = shift;
	my $callback_name = shift;
	my $callback_args = shift;
	
	my $debug_message = "[eventMacro] Callback Happenned, type: '".$callback_type."'";
	
	my $check_list_hash;
	
	if ($callback_type eq 'variable') {
		my $sub_type = shift;
		my $complement = shift;
		$debug_message .= ", variable type: '".$sub_type."'";
		
		if ($sub_type eq 'scalar') {
			$check_list_hash = $self->{'Event_Related_Scalar_Variables'}{$callback_name};
			$callback_name = '$'.$callback_name;
			
		} elsif ($sub_type eq 'array') {
			$check_list_hash = $self->{'Event_Related_Array_Variables'}{$callback_name};
			$callback_name = '@'.$callback_name;
			
		} elsif ($sub_type eq 'accessed_array') {
			$check_list_hash = $self->{'Event_Related_Accessed_Array_Variables'}{$callback_name}{$complement};
			$callback_name = '$'.$callback_name.'['.$complement.']';
			$debug_message .= ", array index: '".$complement."'";
			
		} elsif ($sub_type eq 'hash') {
			$check_list_hash = $self->{'Event_Related_Hash_Variables'}{$callback_name};
			$callback_name = '%'.$callback_name;
			
		} elsif ($sub_type eq 'accessed_hash') {
			$check_list_hash = $self->{'Event_Related_Accessed_Hash_Variables'}{$callback_name}{$complement};
			$callback_name = '$'.$callback_name.'{'.$complement.'}';
			$debug_message .= ", hash key: '".$complement."'";
		}
	} else {
		$check_list_hash = $self->{'Event_Related_Hooks'}{$callback_name};
	}
	
	$debug_message .= ", name: '".$callback_name."'\n";
	
	debug $debug_message, "eventMacro", 2;
	
	my ($event_type_automacro_call_index, $event_type_automacro_call_priority);
	
	foreach my $automacro_index (keys %{$check_list_hash}) {
		my ($automacro, $conditions_indexes_hash, $check_event_type) = ($self->{Automacro_List}->get($automacro_index), $check_list_hash->{$automacro_index}, 0);
		
		debug "[eventMacro] Conditions of state type will be checked in automacro '".$automacro->get_name()."'.\n", "eventMacro", 2;
		
		my @conditions_indexes_array = keys %{ $conditions_indexes_hash };
		
		foreach my $condition_index (@conditions_indexes_array) {
			my $condition = $automacro->{conditionList}->get($condition_index);
			
			if ($condition->condition_type == EVENT_TYPE) {
				debug "[eventMacro] Skipping condition '".$condition->get_name."' of index '".$condition->get_index."' because it is of the event type.\n", "eventMacro", 3;
				$check_event_type = 1;
				next;
			} else {
				debug "[eventMacro] Variable value will be updated in condition of state type in automacro '".$automacro->get_name()."'.\n", "eventMacro", 3 if ($callback_type eq 'variable');
				
				my $result = $automacro->check_state_type_condition($condition_index, $callback_type, $callback_name, $callback_args);
				
				#add to running queue
				if (!$result && $automacro->running_status) {
					$self->remove_from_triggered_prioritized_automacros_index_list($automacro);
				
				#remove from running queue
				} elsif ($result && $automacro->can_be_added_to_queue) {
					$self->add_to_triggered_prioritized_automacros_index_list($automacro);
					
				}
			}
		}
		
		if ($check_event_type) {
		
			if ($callback_type eq 'variable') {
				debug "[eventMacro] Variable value will be updated in condition of event type in automacro '".$automacro->get_name()."'.\n", "eventMacro", 3;
				$automacro->check_event_type_condition($callback_type, $callback_name, $callback_args);
				
			} elsif (($self->get_automacro_checking_status == CHECKING_AUTOMACROS || $self->get_automacro_checking_status == CHECKING_FORCED_BY_USER) && $automacro->can_be_run_from_event && $self->{automacros_index_to_AI_check_state}{$automacro_index}{$AI} == 1) {
				debug "[eventMacro] Condition of event type will be checked in automacro '".$automacro->get_name()."'.\n", "eventMacro", 3;
				
				if ($automacro->check_event_type_condition($callback_type, $callback_name, $callback_args)) {
					debug "[eventMacro] Condition of event type was fulfilled.\n", "eventMacro", 3;
					
					if (!defined $event_type_automacro_call_priority) {
						debug "[eventMacro] Automacro '".$automacro->get_name."' of priority '".$automacro->get_parameter('priority')."' was added to the top of queue.\n", "eventMacro", 3;
						$event_type_automacro_call_index = $automacro_index;
						$event_type_automacro_call_priority = $automacro->get_parameter('priority');
					
					} elsif ($event_type_automacro_call_priority >= $automacro->get_parameter('priority')) {
						debug "[eventMacro] Automacro '".$automacro->get_name."' of priority '".$automacro->get_parameter('priority')."' was added to the top of queue and took place of automacro '".$self->{Automacro_List}->get($event_type_automacro_call_index)->get_name."' which has priority '".$event_type_automacro_call_priority."'.\n", "eventMacro", 3;
						$event_type_automacro_call_index = $automacro_index;
						$event_type_automacro_call_priority = $automacro->get_parameter('priority');
						
					} else {
						debug "[eventMacro] Automacro '".$automacro->get_name()."' was not added to running queue because there already is a higher priority event only automacro in it (automacro '".$self->{Automacro_List}->get($event_type_automacro_call_index)->get_name."' which has priority '".$event_type_automacro_call_priority."').\n", "eventMacro", 3;
					
					}
					
				} else {
					debug "[eventMacro] Condition of event type was not fulfilled.\n", "eventMacro", 3;
					
				}
				
			} else {
				debug "[eventMacro] Condition of event type will not be checked in automacro '".$automacro->get_name()."' because it is not necessary.\n", "eventMacro", 3;
			
			}
		}
	}
	
	if (defined $event_type_automacro_call_index) {
	
		my $automacro = $self->{Automacro_List}->get($event_type_automacro_call_index);
		
		message "[eventMacro] Event of type '".$callback_type."', and of name '".$callback_name."' activated automacro '".$automacro->get_name()."', calling macro '".$automacro->get_parameter('call')."'\n", "system";
		
		$self->call_macro($automacro);
	}
}

# For '$add_or_delete' value '0' is for delete and '1' is for add.
sub manage_dynamic_hook_add_and_delete {
	my ($self, $hook_name, $automacro_index, $condition_index, $add_or_delete) = @_;
	
	my $automacro = $self->{Automacro_List}->get($automacro_index);
	
	my $condition = $automacro->{conditionList}->get($condition_index);
	
	if ($add_or_delete == 1) {
		if (exists $self->{Event_Related_Hooks}{$hook_name}{$automacro_index}{$condition_index}) {
			error "[eventMacro] Condition '".$condition->get_name()."', of index '".$condition_index."' on automacro '".$automacro->get_name()."' tried to add hook '".$hook_name."' to callbacks but it already is in it.\n";
			return;
		}
		
		debug "[eventMacro] Condition '".$condition->get_name()."', of index '".$condition_index."' on automacro '".$automacro->get_name()."' added hook '".$hook_name."' to callbacks.\n", "eventMacro", 3;
		$self->{Event_Related_Hooks}{$hook_name}{$automacro_index}{$condition_index} = undef;
		
		unless (exists $self->{Hook_Handles}{$hook_name}) {
			my $event_sub = sub { $self->manage_event_callbacks('hook', shift, shift); };
			$self->{Hook_Handles}{$hook_name} = Plugins::addHook( $hook_name, $event_sub, undef );
		}
	
	} else {
		if (!exists $self->{Event_Related_Hooks}{$hook_name}{$automacro_index}{$condition_index}) {
			error "[eventMacro] Condition '".$condition->get_name()."', of index '".$condition_index."' on automacro '".$automacro->get_name()."' tried to delte hook '".$hook_name."' from callbacks but it isn't in it.\n";
			return;
		}
		
		debug "[eventMacro] Condition '".$condition->get_name()."', of index '".$condition_index."' on automacro '".$automacro->get_name()."' deleted hook '".$hook_name."' from callbacks.\n", "eventMacro", 3;
		delete $self->{Event_Related_Hooks}{$hook_name}{$automacro_index}{$condition_index};
		
		unless (scalar keys %{$self->{Event_Related_Hooks}{$hook_name}{$automacro_index}}) {
			delete $self->{Event_Related_Hooks}{$hook_name}{$automacro_index};
			unless (scalar keys %{$self->{Event_Related_Hooks}{$hook_name}}) {
				delete $self->{Event_Related_Hooks}{$hook_name};
				Plugins::delHook($self->{Hook_Handles}{$hook_name});
				delete $self->{Hook_Handles}{$hook_name};
			}
		}
	}
}

sub AI_start_checker {
	my ($self, $state) = @_;
	
	foreach my $array_member (@{$self->{triggered_prioritized_automacros_index_list}}) {
		
		next unless ($self->{automacros_index_to_AI_check_state}{$array_member->{index}}{$state} == 1);
		
		my $automacro = $self->{Automacro_List}->get($array_member->{index});
		
		next unless $automacro->is_timed_out;
		
		message "[eventMacro] Conditions met for automacro '".$automacro->get_name()."', calling macro '".$automacro->get_parameter('call')."'\n", "system";
		
		$self->call_macro($automacro);
		
		return;
	}
}

sub disable_automacro {
	my ($self, $automacro) = @_;
	$automacro->disable;
	if ($automacro->running_status) {
		$self->remove_from_triggered_prioritized_automacros_index_list($automacro);
	}
}

sub enable_automacro {
	my ($self, $automacro) = @_;
	$automacro->enable;
	if ($automacro->can_be_added_to_queue) {
		$self->add_to_triggered_prioritized_automacros_index_list($automacro);
	}
}

sub call_macro {
	my ($self, $automacro) = @_;
	
	if (defined $self->{Macro_Runner}) {
		$self->clear_queue();
	}
	
	$automacro->set_timeout_time(time);
	if ($automacro->get_parameter('run-once')) {
		$self->disable_automacro($automacro);
	}
	
	my $new_variables = $automacro->get_new_macro_variables;
	
	my @variable_names = keys %{ $new_variables };
	
	foreach my $variable_name (@variable_names) {
		my $variable_value = $new_variables->{$variable_name};
		$self->set_scalar_var($variable_name, $variable_value, 0);
	}
	
	$self->{Macro_Runner} = new eventMacro::Runner(
		$automacro->get_parameter('call'),
		$automacro->get_parameter('repeat'),
		$automacro->get_parameter('exclusive') ? 0 : 1,
		$automacro->get_parameter('overrideAI'),
		$automacro->get_parameter('orphan'),
		$automacro->get_parameter('delay'),
		$automacro->get_parameter('macro_delay'),
		0
	);
	
	if (defined $self->{Macro_Runner}) {
		my $iterate_macro_sub = sub { $self->iterate_macro(); };
		$self->{AI_start_Macros_Running_Hook_Handle} = Plugins::addHook( 'AI_start', $iterate_macro_sub, undef );
	} else {
		error "[eventMacro] unable to create macro queue.\n"
	}
}

# Function responsible for actually running the macro script
sub iterate_macro {
	my $self = shift;
	
	# These two cheks are actually not necessary, but they can prevent future code bugs.
	if ( !defined $self->{Macro_Runner} ) {
		debug "[eventMacro] For some reason the running macro object got undefined, clearing queue to prevent errors.\n", "eventMacro", 2;
		$self->clear_queue();
		return;
	} elsif ($self->{Macro_Runner}->finished) {
		debug "[eventMacro] For some reason macro '".$self->{Macro_Runner}->get_name()."' finished but 'processCmd' did not clear it, clearing queue to prevent errors.\n", "eventMacro", 2;
		$self->clear_queue();
		return;
	}
	
	return if $self->{Macro_Runner}->is_paused();
	
	my $macro_timeout = $self->{Macro_Runner}->timeout;
	
	if (timeOut($macro_timeout) && $self->ai_is_eventMacro) {
		do {
			last unless ( $self->processCmd( $self->{Macro_Runner}->next ) );
		} while ($self->{Macro_Runner} && !$self->{Macro_Runner}->is_paused() && $self->{Macro_Runner}->macro_block);
	}
}

sub ai_is_eventMacro {
	my $self = shift;
	return 1 if $self->{Macro_Runner}->last_subcall_overrideAI;

	# now check for orphaned script object
	# may happen when messing around with "ai clear" and stuff.
	$self->enforce_orphan if (defined $self->{Macro_Runner} && !AI::inQueue('eventMacro'));
	
	return AI::is('eventMacro', 'deal')
}

sub enforce_orphan {
	my $self = shift;
	my $method = $self->{Macro_Runner}->last_subcall_orphan;
	message "[eventMacro] Running macro '".$self->{Macro_Runner}->last_subcall_name."' got orphaned, its orphan method is '".$method."'.\n";
	
	# 'terminate' undefs the whole macro tree and returns "ai is not idle"
	if ($method eq 'terminate') {
		$self->clear_queue();
		return 0;
		
	# 'terminate_last_call' undefs only the specific macro call that got orphaned, keeping the rest of the macro call tree.
	} elsif ($method eq 'terminate_last_call') {
		my $macro = $self->{Macro_Runner};
		if (defined $macro->{subcall}) {
			while (defined $macro->{subcall}) {
				#cheap way of stopping on the second to last subcall
				last if (!defined $macro->{subcall}->{subcall});
				$macro = $macro->{subcall};
			}
			$macro->clear_subcall;
		} else {
			#since there was no subcall we delete all macro tree
			$self->clear_queue();
		}
		return 0;
		
	# 'reregister' re-inserts "eventMacro" in ai_queue at the first position
	} elsif ($method eq 'reregister') {
		my $macro = $self->{Macro_Runner};
		while (defined $macro->{subcall}) {
			$macro = $macro->{subcall};
		}
		$macro->register;
		return 1;
		
	# 'reregister_safe' waits until AI is idle then re-inserts "eventMacro"
	} elsif ($method eq 'reregister_safe') {
		if (AI::isIdle || AI::is('deal')) {
			my $macro = $self->{Macro_Runner};
			while (defined $macro->{subcall}) {
				$macro = $macro->{subcall};
			}
			$macro->register;
			return 1
		}
		return 0;
		
	} else {
		error "[eventMacro] Unknown orphan method '".$method."'. terminating whole macro tree\n", "eventMacro";
		$self->clear_queue();
		return 0;
	}
}

sub processCmd {
	my ($self, $command) = @_;
	my $macro_name = $self->{Macro_Runner}->last_subcall_name;
	if (defined $command) {
		if ($command ne '') {
			unless (Commands::run($command)) {
				my $error_message = sprintf("[eventMacro] %s failed with %s\n", $macro_name, $command);
				
				error $error_message, "eventMacro";
				$self->clear_queue();
				return;
			}
		}
		if (defined $self->{Macro_Runner} && $self->{Macro_Runner}->finished) {
			$self->clear_queue();
		} else {
			$self->{Macro_Runner}->ok;
		}
	} else {
		my $macro = $self->{Macro_Runner};
		while (defined $macro->{subcall}) {
			$macro = $macro->{subcall};
		}
		my $error_message = $macro->error_message;
		
		error $error_message, "eventMacro";
		$self->clear_queue();
		return;
	}
	
	return 1;
}

sub clear_queue {
	my ($self) = @_;
	debug "[eventMacro] Clearing queue\n", "eventMacro", 2;
	if ( defined $self->{Macro_Runner} && $self->get_automacro_checking_status() == PAUSED_BY_EXCLUSIVE_MACRO ) {
		debug "[eventMacro] Uninterruptible macro '".$self->{Macro_Runner}->last_subcall_name."' ended. Automacros will return to being checked.\n", "eventMacro", 2;
		$self->set_automacro_checking_status(CHECKING_AUTOMACROS);
	}
	$self->{Macro_Runner} = undef;
	Plugins::delHook($self->{AI_start_Macros_Running_Hook_Handle}) if (defined $self->{AI_start_Macros_Running_Hook_Handle});
	$self->{AI_start_Macros_Running_Hook_Handle} = undef;
}


1;
