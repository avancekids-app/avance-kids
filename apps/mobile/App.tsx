import React, { useEffect, useRef, useState } from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import * as SplashScreen from 'expo-splash-screen';
import { useFonts, Inter_400Regular, Inter_500Medium, Inter_600SemiBold } from '@expo-google-fonts/inter';
import { Mulish_400Regular, Mulish_600SemiBold, Mulish_700Bold, Mulish_800ExtraBold } from '@expo-google-fonts/mulish';
import type { Session } from '@supabase/supabase-js';

import './src/utils/webAlertShim';
import { supabase, linkDeSenha } from './src/lib/supabase';
import { novaSenhaPendente } from './src/services/auth';
import { useProfileStore } from './src/store/useProfileStore';
import { destinoAoEntrar, ROTA_COMPLETAR_CADASTRO, ROTA_FIM_DO_TESTE } from './src/lib/destinoAoEntrar';
import { useTermsGate } from './src/store/useTermsGate';
import { navigationRef, irParaLogin } from './src/lib/navigation';
import { AnimatedSplash } from './src/components/AnimatedSplash';
import { TermsGate } from './src/components/TermsGate';
import { PwaInstallPrompt } from './src/components/PwaInstallPrompt';

import { LoginScreen } from './src/screens/LoginScreen';
import { ParentRegisterScreen } from './src/screens/ParentRegisterScreen';
import { ChildRegisterScreen } from './src/screens/ChildRegisterScreen';
import { Onboarding1Screen } from './src/screens/Onboarding1Screen';
import { PerguntasScreen } from './src/screens/PerguntasScreen';
import { Onboarding2Screen } from './src/screens/Onboarding2Screen';
import { TriagemScreen } from './src/screens/TriagemScreen';
import { HabilidadeScreen } from './src/screens/HabilidadeScreen';
import { Onboarding3Screen } from './src/screens/Onboarding3Screen';
import { HomeScreen } from './src/screens/HomeScreen';
import { ActivityPlanScreen } from './src/screens/ActivityPlanScreen';
import { ActivityScreen } from './src/screens/ActivityScreen';
import { SettingsScreen } from './src/screens/SettingsScreen';
import { EditParentProfileScreen } from './src/screens/EditParentProfileScreen';
import { ChildrenListScreen } from './src/screens/ChildrenListScreen';
import { EditChildProfileScreen } from './src/screens/EditChildProfileScreen';
import { ChangePasswordScreen } from './src/screens/ChangePasswordScreen';
import { ActivityHistoryScreen } from './src/screens/ActivityHistoryScreen';
import { PlansScreen } from './src/screens/PlansScreen';
import { ContentDetailScreen } from './src/screens/ContentDetailScreen';
import { ContentListScreen } from './src/screens/ContentListScreen';
import { DialogHost, showError } from './src/ui/dialog';

const Stack = createNativeStackNavigator();
const ROTA_NOVA_SENHA = 'NovaSenha';

// Keep the splash screen visible while we fetch resources
SplashScreen.preventAutoHideAsync();

export default function App() {
  const [fontsLoaded] = useFonts({
    Inter_400Regular,
    Inter_500Medium,
    Inter_600SemiBold,
    Mulish_400Regular,
    Mulish_600SemiBold,
    Mulish_700Bold,
    Mulish_800ExtraBold,
  });

  const [session, setSession] = useState<Session | null>(null);
  const [sessionLoaded, setSessionLoaded] = useState(false);
  const [abrirNovaSenha, setAbrirNovaSenha] = useState(false);

  useEffect(() => {
    // A avaliação dos termos entra no MESMO tick do setSession: o React agrupa
    // os dois no mesmo commit, então o navigator nunca chega a renderizar as
    // telas autenticadas antes de o gate ter opinião. Feita num efeito
    // separado, havia um commit com a Home montada (e buscando dados) antes de
    // qualquer verificação.
    const aplicarSessao = (proxima: Session | null) => {
      setSession(proxima);
      const id = proxima?.user.id;
      if (id) {
        void useTermsGate.getState().avaliar(id);
      } else {
        setAbrirNovaSenha(false);
        useTermsGate.getState().limpar();
        void novaSenhaPendente.limpar().catch(() => {});
        // Perder a sessão no meio do bloqueio apenas escondia o gate e deixava
        // o app navegável nas telas autenticadas. No boot deslogado o
        // navigator ainda não existe e isto é inócuo.
        irParaLogin();
      }
    };

    supabase.auth
      .getSession()
      .then(async ({ data }) => {
        const userId = data.session?.user.id;
        if (linkDeSenha) {
          // linkDeSenha só existe no web. O cliente só limpa a URL quando o link dá certo.
          window.history.replaceState(null, '', window.location.pathname + window.location.search);
          // Só a sessão criada pelo próprio link dispensa a senha atual.
          const doLink = !!linkDeSenha.accessToken && data.session?.access_token === linkDeSenha.accessToken;
          if (doLink && userId) {
            await novaSenhaPendente.marcar(userId).catch(() => {});
          } else {
            showError('Link expirado', 'Este link já foi usado ou expirou. Peça um novo em "Esqueci a senha".');
          }
        }
        // Recarregar a página antes de salvar reabre a tela, em vez de deixar a conta logada sem senha.
        const pendente = userId ? await novaSenhaPendente.ler().catch(() => null) : null;
        setAbrirNovaSenha(!!userId && pendente === userId);
        aplicarSessao(data.session);
      })
      // Sem catch, uma falha aqui deixava o app preso na splash para sempre.
      .catch((err) => console.warn('[auth] getSession falhou:', err))
      .finally(() => setSessionLoaded(true));
    const { data: subscription } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      aplicarSessao(nextSession);
    });
    return () => subscription.subscription.unsubscribe();
  }, []);

  const userId = session?.user.id;
  const previousUserId = useRef<string | undefined>(undefined);
  const [perfilCarregado, setPerfilCarregado] = useState(false);
  const [rotaInicial, setRotaInicial] = useState<string>('Home');
  useEffect(() => {
    if (userId) {
      useProfileStore
        .getState()
        .loadAll()
        .then(destinoAoEntrar)
        .then((destino) => setRotaInicial(destino.name))
        .catch((err) => console.warn('[profile] loadAll falhou:', err))
        .finally(() => setPerfilCarregado(true));
    } else if (previousUserId.current) {
      // Só no logout. No boot a sessão ainda não carregou: limpar aqui apagava
      // a criança escolhida e o app sempre abria na criança mais recente.
      useProfileStore.getState().reset();
    }
    previousUserId.current = userId;
  }, [userId]);

  // Com sessão, a tela inicial vem de destinoAoEntrar (cadastro incompleto ou
  // teste grátis encerrado abrem direto na tela certa, sem passar pela Home).
  // Só vale no boot: depois de pronto o navigator não pode desmontar num login.
  const [bootPronto, setBootPronto] = useState(false);
  useEffect(() => {
    if (!bootPronto && sessionLoaded && (!session || perfilCarregado)) setBootPronto(true);
  }, [bootPronto, sessionLoaded, session, perfilCarregado]);

  const ready = fontsLoaded && bootPronto;

  // Esconde a splash nativa assim que o JS assume — o AnimatedSplash
  // (logo com pulse) cobre o restante do carregamento.
  useEffect(() => {
    SplashScreen.hideAsync();
  }, []);

  if (!ready) {
    return <AnimatedSplash />;
  }

  return (
    <SafeAreaProvider>
      <NavigationContainer ref={navigationRef}>
        <Stack.Navigator
          initialRouteName={session ? (abrirNovaSenha ? ROTA_NOVA_SENHA : rotaInicial) : 'Login'}
          screenOptions={{ headerShown: false, animation: 'slide_from_right' }}
        >
          <Stack.Screen name="Login" component={LoginScreen} />
          <Stack.Screen name="ParentRegister" component={ParentRegisterScreen} />
          <Stack.Screen
            name={ROTA_COMPLETAR_CADASTRO.name}
            component={ParentRegisterScreen}
            initialParams={{ completarCadastro: true }}
          />
          <Stack.Screen name="ChildRegister" component={ChildRegisterScreen} />
          <Stack.Screen name="Onboarding1" component={Onboarding1Screen} />
          <Stack.Screen name="Perguntas" component={PerguntasScreen} />
          <Stack.Screen name="Onboarding2" component={Onboarding2Screen} />
          <Stack.Screen name="Triagem" component={TriagemScreen} />
          <Stack.Screen name="Habilidade" component={HabilidadeScreen} />
          <Stack.Screen name="Onboarding3" component={Onboarding3Screen} />
          <Stack.Screen name="Home" component={HomeScreen} />
          <Stack.Screen name="ActivityPlan" component={ActivityPlanScreen} />
          <Stack.Screen name="Activity" component={ActivityScreen} />
          <Stack.Screen name="Settings" component={SettingsScreen} />
          <Stack.Screen name="EditParentProfile" component={EditParentProfileScreen} />
          <Stack.Screen name="ChildrenList" component={ChildrenListScreen} />
          <Stack.Screen name="EditChildProfile" component={EditChildProfileScreen} />
          <Stack.Screen name="ChangePassword" component={ChangePasswordScreen} />
          <Stack.Screen
            name={ROTA_NOVA_SENHA}
            component={ChangePasswordScreen}
            initialParams={{ recuperacao: true }}
          />
          <Stack.Screen name="ActivityHistory" component={ActivityHistoryScreen} />
          <Stack.Screen name="Plans" component={PlansScreen} />
          <Stack.Screen
            name={ROTA_FIM_DO_TESTE.name}
            component={PlansScreen}
            initialParams={{ fimDoTeste: true }}
          />
          <Stack.Screen name="ContentDetail" component={ContentDetailScreen} />
          <Stack.Screen name="ContentList" component={ContentListScreen} />
        </Stack.Navigator>
      </NavigationContainer>
      <DialogHost />
      {/* Recuperar a conta não exige um novo aceite; o gate volta após o logout. */}
      {!abrirNovaSenha && <TermsGate />}
      <PwaInstallPrompt />
    </SafeAreaProvider>
  );
}
