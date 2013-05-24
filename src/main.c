#include "communication.h"
#include "interpreter.h"
#include "register.h"
#include "spec_build.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

//LIBs
#include <libnetconf.h>
#include <libxml/parser.h>

static const char *CONFIG_MODEL_PATH = SOURCE_DIRECTORY "/specs/config.yin";

void callback_print(NC_VERB_LEVEL level, const char *msg) {
	const char *level_message = "<UNKNOWN>";
	switch (level) {
		case NC_VERB_ERROR:
			level_message = "ERROR";
			break;
		case NC_VERB_WARNING:
			level_message = "WARNING";
			break;
		case NC_VERB_VERBOSE:
			level_message = "VERBOSE";
			break;
		case NC_VERB_DEBUG:
			level_message = "DEBUG";
			break;
	}
	fprintf(stderr, "%s\t%s\n", level_message, msg);
}

int main(int argc, const char *argv[]) {
	(void) argc;
	(void) argv;

	//some setting
	//Set verbosity and function to print libnetconf's messages
	nc_verbosity(NC_VERB_DEBUG);
	nc_callback_print(callback_print);

	//Initialize libxml2 library
	xmlInitParser();
		LIBXML_TEST_VERSION

	struct interpreter *interpreter = interpreter_create();
	if (!interpreter_load_plugins(interpreter, PLUGIN_PATH))
		return 1;

	char *config_file = spec_build(CONFIG_MODEL_PATH, PLUGIN_PATH, get_submodels());
	bool init = comm_init(config_file, &global_srv_config, interpreter);
	//unlink(config_file);
	free(config_file);

	if (!init) {
		//error message was generated by callback_print
		return 1;
	}

	comm_start_loop(&global_srv_config);
	comm_cleanup(&global_srv_config);

	interpreter_destroy(interpreter);

	//Clean up phase of libxml2
	xmlCleanupParser();
	xmlMemoryDump();

	return 0;
}
