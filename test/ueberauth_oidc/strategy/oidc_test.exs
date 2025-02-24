defmodule Ueberauth.Strategy.OIDCTest do
  use ExUnit.Case
  use Ueberauth.Strategy

  import Mock

  alias Ueberauth.Strategy.Helpers
  alias Ueberauth.Strategy.OIDC

  @request_uri "https://oidc.local/request"
  @callback_uri "https://oidc.local/callback"
  @valid_tokens {:ok, %{"access_token" => "1234", "id_token" => "4321"}}
  @valid_claims {:ok, %{"uid" => "1234"}}
  @error_response {:error, "reason"}

  describe "OIDC Strategy" do
    setup_with_mocks [
      {OpenIDConnect, [],
       [
         authorization_uri: fn
           "test_provider", %{redirect_uri: redirect_uri} = params ->
             state_param =
               case params[:state] do
                 nil -> ""
                 state -> "&state=#{state}"
               end

             "#{@request_uri}?redirect_uri=#{redirect_uri}#{state_param}"
         end,
         fetch_tokens: fn _, _ -> @valid_tokens end,
         verify: fn _, _ -> @valid_claims end
       ]},
      {Helpers, [],
       [
         options: fn _ -> [] end,
         set_errors!: fn _, _ -> nil end,
         error: fn key, msg -> {key, msg} end,
         redirect!: fn _, url -> url end,
         callback_url: fn _ -> @callback_uri end
       ]}
    ] do
      :ok
    end

    test "Handles an OIDC request" do
      request =
        OIDC.handle_request!(%Plug.Conn{
          params: %{"oidc_provider" => "test_provider"},
          private: %{ueberauth_request_options: %{options: []}}
        })

      assert request == "#{@request_uri}?redirect_uri=#{@callback_uri}"
    end

    test "Handles an OIDC request with a state param" do
      request =
        OIDC.handle_request!(%Plug.Conn{
          params: %{"oidc_provider" => "test_provider"},
          private: %{
            ueberauth_request_options: %{options: []},
            ueberauth_state_param: "test_state"
          }
        })

      assert request == "#{@request_uri}?redirect_uri=#{@callback_uri}&state=test_state"
    end

    test "Handles an error in an OIDC request" do
      OIDC.handle_request!(%Plug.Conn{
        params: %{"oidc_provider" => "unregistered_provider"},
        private: %{ueberauth_request_options: %{options: []}}
      })

      assert_called(
        Helpers.set_errors!(:_, [
          {"error", "Authorization URL could not be constructed"}
        ])
      )
    end

    test "Handle callback from provider with a redirect_uri" do
      with_mock Application, [],
        get_env: fn :ueberauth, OIDC, [] ->
          [test_provider: [redirect_uri: "https://oidc.local/custom"]]
        end do
        request =
          OIDC.handle_request!(%Plug.Conn{
            params: %{"oidc_provider" => "test_provider"},
            private: %{ueberauth_request_options: %{options: []}}
          })

        assert request =~ ~r|\?redirect_uri=https://oidc.local/custom$|
      end
    end

    test "Handle callback from provider with a uid_field in the id_token" do
      with_mock Application, [],
        get_env: fn :ueberauth, OIDC, [] ->
          [test_provider: [fetch_userinfo: false, uid_field: "uid"]]
        end do
        callback =
          OIDC.handle_callback!(%Plug.Conn{
            params: %{"code" => 1234, "oidc_provider" => "test_provider"},
            private: %{ueberauth_request_options: %{options: []}}
          })

        assert %Plug.Conn{
                 private: %{
                   ueberauth_oidc_opts: [
                     provider: "test_provider",
                     fetch_userinfo: false,
                     uid_field: _
                   ],
                   ueberauth_oidc_tokens: %{"access_token" => _, "id_token" => _}
                 }
               } = callback
      end
    end

    test "Handle callback from provider with a user_info endpoint" do
      with_mocks [
        {GenServer, [],
         [call: fn _, _ -> %{"userinfo_endpoint" => "https://oidc.test/userinfo"} end]},
        {HTTPoison, [],
         [
           get!: fn _, _ ->
             %HTTPoison.Response{body: "{\"sub\":\"string_key\",\"uid\":\"atom_key\"}"}
           end
         ]},
        {Application, [],
         [
           get_env: fn
             :ueberauth, OIDC, [] ->
               [test_provider: [fetch_userinfo: true, userinfo_uid_field: "uid"]]

             :ueberauth_oidc, _, default ->
               default
           end
         ]}
      ] do
        callback =
          OIDC.handle_callback!(%Plug.Conn{
            params: %{"code" => 1234, "oidc_provider" => "test_provider"},
            private: %{ueberauth_request_options: %{options: []}}
          })

        assert %Plug.Conn{
                 private: %{
                   ueberauth_oidc_opts: [
                     provider: "test_provider",
                     fetch_userinfo: true,
                     userinfo_uid_field: "uid"
                   ],
                   ueberauth_oidc_tokens: %{"access_token" => _, "id_token" => _},
                   ueberauth_oidc_user_info: %{"sub" => "string_key", "uid" => "atom_key"}
                 }
               } = callback
      end
    end

    test "Handle callback from provider with a missing code" do
      OIDC.handle_callback!(%Plug.Conn{params: %{}})

      assert_called(
        Helpers.set_errors!(:_, [
          {"error", "Query string does not contain field 'code'"}
        ])
      )
    end

    test "Handle callback from provider with an error fetching tokens" do
      with_mock OpenIDConnect, fetch_tokens: fn _, _ -> @error_response end do
        OIDC.handle_callback!(%Plug.Conn{
          params: %{"code" => 1234, "oidc_provider" => "test_provider"},
          private: %{ueberauth_request_options: %{options: []}}
        })

        assert_called(OpenIDConnect.fetch_tokens("test_provider", %{code: 1234}))
        refute called(OpenIDConnect.verify("test_provider", "4321"))
        assert_called(Helpers.set_errors!(:_, [{"error", "reason"}]))
      end
    end

    test "Handle callback from provider with an error verifying tokens" do
      with_mock OpenIDConnect,
        fetch_tokens: fn _, _ -> @valid_tokens end,
        verify: fn _, _ -> @error_response end do
        OIDC.handle_callback!(%Plug.Conn{
          params: %{"code" => 1234, "oidc_provider" => "test_provider"},
          private: %{ueberauth_request_options: %{options: []}}
        })

        assert_called(OpenIDConnect.fetch_tokens("test_provider", %{code: 1234}))
        assert_called(OpenIDConnect.verify("test_provider", "4321"))
        assert_called(Helpers.set_errors!(:_, [{"error", "reason"}]))
      end
    end

    test "Handle callback from provider with error type and response" do
      with_mock OpenIDConnect, fetch_tokens: fn _, _ -> {:error, :token_error, "some_message"} end do
        OIDC.handle_callback!(%Plug.Conn{
          params: %{"code" => 1234, "oidc_provider" => "test_provider"},
          private: %{ueberauth_request_options: %{options: []}}
        })

        assert_called(Helpers.set_errors!(:_, [{:token_error, "some_message"}]))
      end
    end

    test "Handle callback from provider with an unknown response" do
      with_mock OpenIDConnect, fetch_tokens: fn _, _ -> {:unknown, "some_message"} end do
        OIDC.handle_callback!(%Plug.Conn{
          params: %{"code" => 1234, "oidc_provider" => "test_provider"},
          private: %{ueberauth_request_options: %{options: []}}
        })

        assert_called(Helpers.set_errors!(:_, [{"unknown_error", {:unknown, "some_message"}}]))
      end
    end

    test "handle cleanup of uberauth values in the conn" do
      conn_with_values = %Plug.Conn{
        private: %{
          ueberauth_oidc_opts: :some_value,
          ueberauth_oidc_claims: :other_value,
          uebrauth_oidc_tokens: :another_value,
          ueberauth_oidc_user_info: :different_value
        }
      }

      assert %Plug.Conn{
               private: %{
                 ueberauth_oidc_opts: nil,
                 ueberauth_oidc_claims: nil,
                 ueberauth_oidc_tokens: nil,
                 ueberauth_oidc_user_info: nil
               }
             } = OIDC.handle_cleanup!(conn_with_values)
    end

    test "Get the uid from the user_info" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_opts: [fetch_userinfo: true, userinfo_uid_field: "upn"],
          ueberauth_oidc_user_info: %{"upn" => "upn_id"}
        }
      }

      assert OIDC.uid(conn) == "upn_id"
    end

    test "Get the uid from the id_token if fetch_userinfo is not set" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_opts: [userinfo_uid_field: "upn", uid_field: "sub"],
          ueberauth_oidc_claims: %{"sub" => "sub_id"},
          ueberauth_oidc_user_info: %{"upn" => "upn_id"},
          ueberauth_oidc_tokens: %{"id_token" => "4321"}
        }
      }

      assert OIDC.uid(conn) == "sub_id"
    end

    test "Return nil if fetch_userinfo and uid_field are not set" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_opts: [userinfo_uid_field: "upn"],
          ueberauth_oidc_claims: %{"sub" => "sub_id"},
          ueberauth_oidc_user_info: %{"upn" => "upn_id"},
          ueberauth_oidc_tokens: %{"id_token" => "4321"}
        }
      }

      assert OIDC.uid(conn) == nil
    end

    test "Get the uid from the id_token" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_opts: [uid_field: "sub"],
          ueberauth_oidc_claims: %{"sub" => "some_uid"},
          ueberauth_oidc_tokens: %{"id_token" => "4321"}
        }
      }

      assert OIDC.uid(conn) == "some_uid"
    end

    test "Return nil when uid_field is invalid" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_opts: [uid_field: "uid"],
          ueberauth_oidc_claims: %{"sub" => "some_uid"},
          ueberauth_oidc_tokens: %{"id_token" => "4321"}
        }
      }

      assert OIDC.uid(conn) == nil
    end

    test "Get credentials from the conn" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_tokens: %{
            "id_token" => "4321",
            "access_token" => "1234",
            "token_type" => "Bearer"
          },
          ueberauth_oidc_claims: %{
            "exp" => 1234
          },
          ueberauth_oidc_opts: [provider: "some_provider"]
        }
      }

      assert %{
               expires: true,
               expires_at: 1234,
               other: %{user_info: nil, provider: "some_provider"},
               token: "1234",
               token_type: "Bearer"
             } = OIDC.credentials(conn)
    end

    test "Parses a binary exp value" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_tokens: %{
            "id_token" => "4321",
            "access_token" => "1234",
            "token_type" => "Bearer"
          },
          ueberauth_oidc_claims: %{
            "exp" => "1234"
          },
          ueberauth_oidc_opts: [provider: "some_provider"]
        }
      }

      assert %{
               expires: true,
               expires_at: 1234,
               other: %{user_info: nil, provider: "some_provider"},
               token: "1234",
               token_type: "Bearer"
             } = OIDC.credentials(conn)
    end

    test "Credentials include a refresh token if provided" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_tokens: %{
            "id_token" => "4321",
            "access_token" => "1234",
            "token_type" => "Bearer",
            "refresh_token" => "5678"
          },
          ueberauth_oidc_claims: %{
            "exp" => 1234
          },
          ueberauth_oidc_opts: [provider: "some_provider"]
        }
      }

      assert %{refresh_token: refresh_token} = OIDC.credentials(conn)

      refute is_nil(refresh_token)
    end

    test "Get info from the conn" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_user_info: %{
            "name" => "name",
            "email" => "email"
          }
        }
      }

      assert %Ueberauth.Auth.Info{
               name: "name",
               email: "email"
             } = OIDC.info(conn)
    end

    test "Get info from the conn and ignore invalid fields" do
      info =
        OIDC.info(%Plug.Conn{
          private: %{
            ueberauth_oidc_user_info: %{
              "name" => "name",
              "foo" => "bar"
            }
          }
        })

      refute Map.has_key?(info, :foo)
      assert %Ueberauth.Auth.Info{name: "name"} = info
    end

    test "Get info from the conn when there is no info field" do
      info = OIDC.info(%Plug.Conn{private: %{}})

      assert %Ueberauth.Auth.Info{name: nil, email: nil} = info
    end

    test "Get info from the conn when fetch_userinfo is disabled" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_user_info: nil
        }
      }

      assert %Ueberauth.Auth.Info{
               name: nil,
               email: nil
             } = OIDC.info(conn)
    end

    test "Puts the raw token map in the Extra struct" do
      conn = %Plug.Conn{
        private: %{
          ueberauth_oidc_tokens: %{"token_key" => "token_value"},
          ueberauth_oidc_claims: %{"claim_key" => "claim_value"},
          ueberauth_oidc_opts: %{"opt_key" => "opt_value"}
        }
      }

      assert OIDC.extra(conn) == %Ueberauth.Auth.Extra{
               raw_info: %{
                 tokens: %{"token_key" => "token_value"},
                 claims: %{"claim_key" => "claim_value"},
                 opts: %{"opt_key" => "opt_value"}
               }
             }
    end
  end
end
