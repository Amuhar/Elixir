REBAR := rebar
ELIXIRC := bin/elixirc --verbose --ignore-module-conflict
ERLC := erlc -I lib/elixir/include
ERL := erl -I lib/elixir/include -noshell -pa lib/elixir/ebin
VERSION := $(strip $(shell cat VERSION))
Q := @
PREFIX := /usr/local
LIBDIR := lib
INSTALL = install
INSTALL_DIR = $(INSTALL) -m755 -d
INSTALL_DATA = $(INSTALL) -m644
INSTALL_PROGRAM = $(INSTALL) -m755

.PHONY: install compile erlang elixir build_plt clean_plt dialyze test clean docs release_docs release_zip check_erlang_release
.NOTPARALLEL: compile

#==> Functions

# This check should work for older versions like R16B
# as well as new verions like 17.1 and 18
define CHECK_ERLANG_RELEASE
	$(Q) erl -noshell -eval 'io:fwrite("~s", [erlang:system_info(otp_release)])' -s erlang halt | grep -q '^1[789]'; \
		if [ $$? != 0 ]; then                                                                                        \
		   echo "At least Erlang 17.0 is required to build Elixir";                                                  \
		   exit 1;                                                                                                   \
		fi;
endef

define APP_TEMPLATE
$(1): lib/$(1)/ebin/Elixir.$(2).beam lib/$(1)/ebin/$(1).app

lib/$(1)/ebin/$(1).app: lib/$(1)/mix.exs
	$(Q) mkdir -p lib/$(1)/_build/shared/lib/$(1)
	$(Q) cp -R lib/$(1)/ebin lib/$(1)/_build/shared/lib/$(1)/
	$(Q) cd lib/$(1) && ../../bin/elixir -e 'Mix.start(:permanent, [])' -r mix.exs -e 'Mix.Task.run("compile.app")'
	$(Q) cp lib/$(1)/_build/shared/lib/$(1)/ebin/$(1).app lib/$(1)/ebin/$(1).app
	$(Q) rm -rf lib/$(1)/_build

lib/$(1)/ebin/Elixir.$(2).beam: $(wildcard lib/$(1)/lib/*.ex) $(wildcard lib/$(1)/lib/*/*.ex) $(wildcard lib/$(1)/lib/*/*/*.ex)
	@ echo "==> $(1) (compile)"
	@ rm -rf lib/$(1)/ebin
	$(Q) cd lib/$(1) && ../../$$(ELIXIRC) "lib/**/*.ex" -o ebin

test_$(1): $(1)
	@ echo "==> $(1) (exunit)"
	$(Q) cd lib/$(1) && ../../bin/elixir -r "test/test_helper.exs" -pr "test/**/*_test.exs";
endef

#==> Compilation tasks

KERNEL:=lib/elixir/ebin/Elixir.Kernel.beam
UNICODE:=lib/elixir/ebin/Elixir.String.Unicode.beam

default: compile

compile: lib/elixir/src/elixir.app.src erlang elixir

lib/elixir/src/elixir.app.src: src/elixir.app.src
	$(Q) $(call CHECK_ERLANG_RELEASE)
	$(Q) rm -rf lib/elixir/src/elixir.app.src
	$(Q) echo "%% This file is automatically generated from <project_root>/src/elixir.app.src" \
	                             >lib/elixir/src/elixir.app.src
	$(Q) cat src/elixir.app.src >>lib/elixir/src/elixir.app.src

erlang:
	$(Q) cd lib/elixir && ../../$(REBAR) compile

# Since Mix depends on EEx and EEx depends on
# Mix, we first compile EEx without the .app
# file, then mix and then compile EEx fully
elixir: stdlib lib/eex/ebin/Elixir.EEx.beam mix ex_unit logger eex iex

stdlib: $(KERNEL) VERSION
$(KERNEL): lib/elixir/lib/*.ex lib/elixir/lib/*/*.ex lib/elixir/lib/*/*/*.ex
	$(Q) if [ ! -f $(KERNEL) ]; then                    \
		echo "==> bootstrap (compile)";                 \
		$(ERL) -s elixir_compiler core -s erlang halt;  \
	fi
	@ echo "==> elixir (compile)";
	$(Q) cd lib/elixir && ../../$(ELIXIRC) "lib/kernel.ex" -o ebin;
	$(Q) cd lib/elixir && ../../$(ELIXIRC) "lib/**/*.ex" -o ebin;
	$(Q) $(MAKE) unicode
	$(Q) rm -rf lib/elixir/ebin/elixir.app
	$(Q) cd lib/elixir && ../../$(REBAR) compile

unicode: $(UNICODE)
$(UNICODE): lib/elixir/unicode/*
	@ echo "==> unicode (compile)";
	@ echo "This step can take up to a minute to compile in order to embed the Unicode database"
	$(Q) cd lib/elixir && ../../$(ELIXIRC) unicode/unicode.ex -o ebin;

$(eval $(call APP_TEMPLATE,ex_unit,ExUnit))
$(eval $(call APP_TEMPLATE,logger,Logger))
$(eval $(call APP_TEMPLATE,eex,EEx))
$(eval $(call APP_TEMPLATE,mix,Mix))
$(eval $(call APP_TEMPLATE,iex,IEx))

install: compile
	@ echo "==> elixir (install)"
	$(Q) for dir in lib/*; do \
		$(INSTALL_DIR) "$(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/$$dir/ebin"; \
		$(INSTALL_DATA) $$dir/ebin/* "$(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/$$dir/ebin"; \
	done
	$(Q) $(INSTALL_DIR) "$(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/bin"
	$(Q) $(INSTALL_PROGRAM) $(filter-out %.ps1, $(filter-out %.bat, $(wildcard bin/*))) "$(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/bin"
	$(Q) $(INSTALL_DIR) "$(DESTDIR)$(PREFIX)/bin"
	$(Q) for file in "$(DESTDIR)$(PREFIX)"/$(LIBDIR)/elixir/bin/* ; do \
		ln -sf "../$(LIBDIR)/elixir/bin/$${file##*/}" "$(DESTDIR)$(PREFIX)/bin/" ; \
	done

clean:
	cd lib/elixir && ../../$(REBAR) clean
	rm -rf ebin
	rm -rf lib/*/ebin
	rm -rf lib/elixir/test/ebin
	rm -rf lib/*/tmp
	rm -rf lib/mix/test/fixtures/git_repo
	rm -rf lib/mix/test/fixtures/deps_on_git_repo
	rm -rf lib/mix/test/fixtures/git_rebar
	rm -rf lib/elixir/src/elixir.app.src

clean_exbeam:
	$(Q) rm -f lib/*/ebin/Elixir.*.beam

#==> Release tasks

SOURCE_REF = $(shell head="$$(git rev-parse HEAD)" tag="$$(git tag --points-at $$head | tail -1)" ; echo "$${tag:-$$head}\c")
DOCS = bin/elixir ../ex_doc/bin/ex_doc "$(1)" "$(VERSION)" "lib/$(2)/ebin" -m "$(3)" -u "https://github.com/elixir-lang/elixir" --source-ref "$(call SOURCE_REF)" -o docs/$(2) -p http://elixir-lang.org/docs.html

docs: compile ../ex_doc/bin/ex_doc
	$(Q) rm -rf docs
	$(call DOCS,Elixir,elixir,Kernel)
	$(call DOCS,EEx,eex,EEx)
	$(call DOCS,Mix,mix,Mix)
	$(call DOCS,IEx,iex,IEx)
	$(call DOCS,ExUnit,ex_unit,ExUnit)
	$(call DOCS,Logger,logger,Logger)

../ex_doc/bin/ex_doc:
	@ echo "ex_doc is not found in ../ex_doc as expected. See README for more information."
	@ false

release_zip: compile
	rm -rf v$(VERSION).zip
	zip -9 -r v$(VERSION).zip bin CHANGELOG.md LEGAL lib/*/ebin LICENSE README.md VERSION

release_docs: docs
	cd ../docs
	rm -rf ../docs/master
	mv docs ../docs/master

#==> Tests tasks

test: test_erlang test_elixir

TEST_ERL = lib/elixir/test/erlang
TEST_EBIN = lib/elixir/test/ebin
TEST_ERLS = $(addprefix $(TEST_EBIN)/, $(addsuffix .beam, $(basename $(notdir $(wildcard $(TEST_ERL)/*.erl)))))

test_erlang: compile $(TEST_ERLS)
	@ echo "==> elixir (eunit)"
	$(Q) $(ERL) -pa $(TEST_EBIN) -s test_helper test;
	@ echo ""

$(TEST_EBIN)/%.beam: $(TEST_ERL)/%.erl
	$(Q) mkdir -p $(TEST_EBIN)
	$(Q) $(ERLC) -o $(TEST_EBIN) $<

test_elixir: test_stdlib test_ex_unit test_logger test_doc_test test_mix test_eex test_iex

test_doc_test: compile
	@ echo "==> doctest (exunit)"
	$(Q) cd lib/elixir && ../../bin/elixir -r "test/doc_test.exs";

test_stdlib: compile
	@ echo "==> elixir (exunit)"
	$(Q) exec epmd & exit
	$(Q) if [ "$(OS)" = "Windows_NT" ]; then \
		cd lib/elixir && cmd //C call ../../bin/elixir.bat -r "test/elixir/test_helper.exs" -pr "test/elixir/**/*_test.exs"; \
	else \
		cd lib/elixir && ../../bin/elixir -r "test/elixir/test_helper.exs" -pr "test/elixir/**/*_test.exs"; \
	fi

#==> Dialyzer tasks

DIALYZER_OPTS = --no_check_plt --fullpath -Werror_handling -Wunmatched_returns -Wrace_conditions -Wunderspecs
PLT = .elixir.plt

$(PLT):
	@ echo "==> Building PLT with Elixir's dependencies..."
	$(Q) dialyzer --output_plt $(PLT) --build_plt --apps erts kernel stdlib compiler syntax_tools parsetools tools ssl inets

clean_plt:
	$(Q) rm -f $(PLT)

build_plt: clean_plt $(PLT)

dialyze: compile $(PLT)
	@ echo "==> Dialyzing Elixir..."
	$(Q) dialyzer --plt $(PLT) $(DIALYZER_OPTS) lib/*/ebin
