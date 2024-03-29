library ieee;
use     ieee.std_logic_1164.all;
use     ieee.std_logic_unsigned.all;
use     ieee.std_logic_misc.all;

entity SERIAL_RX is
  generic (
    F_ZEGARA		:positive := 20_000_000;			-- czestotliwosc zegata w [Hz]
    L_MIN_BODOW		:positive := 110;				-- minimalna predkosc nadawania w [bodach]
    B_SLOWA		:natural range 5 to 8 := 8;			-- liczba bitow slowa danych (5-8)
    B_PARZYSTOSCI       :natural range 0 to 1 := 1;                     -- liczba bitow parzystosci (0-1)
    B_STOPOW            :natural range 0 to 2 := 2;                     -- liczba bitow stopu (1-2)
    N_RX		:boolean := FALSE;				-- negacja logiczna sygnalu szeregowego
    N_SLOWO		:boolean := FALSE				-- negacja logiczna slowa danych
  );
  port (
    R		        :in  std_logic;					-- sygnal resetowania
    C		        :in  std_logic;					-- zegar taktujacy
    T_BODU	        :in  natural range 0 to F_ZEGARA/L_MIN_BODOW;	-- liczba taktow zegara dla jednego bodu
    RX		        :in  std_logic;					-- odebrany sygnal szeregowy
    SLOWO	        :out std_logic_vector(B_SLOWA-1 downto 0);	-- odebrane slowo danych
    GOTOWE	        :out std_logic;					-- flaga potwierdzenia odbioru
    BLAD	        :out std_logic					-- flaga wykrycia bledu w odbiorze
  );
end SERIAL_RX;

architecture behavioural of SERIAL_RX is

  signal   wejscie	:std_logic_vector(0 to 1);			-- podwojny rejestr sygnalu RX

  type     ETAP		is (CZEKANIE, START, DANA, PARZYSTOSC, STOP);	-- lista etapow pracy odbiornika
  signal   stan		:ETAP;						-- rejestr maszyny stanow odbiornika

  constant T_MAX_BODU	:positive := F_ZEGARA/L_MIN_BODOW;		-- czas jednego bodu - liczba takt�w zegara
  signal   l_czasu  	:natural range 0 to T_MAX_BODU-1;		-- licznik czasu jednego bodu
  signal   l_bitow  	:natural range 0 to B_SLOWA-1;			-- licznik odebranych bitow danych lub stopu

  signal   bufor	:std_logic_vector(SLOWO'range);			-- rejestr kolejno odebranych bitow danych
  signal   problem	:std_logic;					-- rejestr (flaga) wykrytego bledu odbioru

begin

   assert (F_ZEGARA>=2*L_MIN_BODOW)					-- badanie poprawnosci ustawien zegarow
     report   "SERIAL_RX: nieprawidlowa wartosc parametru F_ZEGARA = " & integer'image(F_ZEGARA)
              & "i/lub parametru L_MIN_BODOW = "&integer'image(L_MIN_BODOW)
     severity error;

   process (R, C) is							-- proces odbiornika
   begin								-- cialo procesu odbiornika

     if (R='1') then							-- asynchroniczna inicjalizacja rejestrow
       wejscie	<= (others => '0');					-- wyzerowanie rejestru sygnalu RX
       stan	<= CZEKANIE;						-- poczatkowy stan pracy odbiornika
       l_czasu  <= 0;							-- wyzerowanie licznika czasu bodu
       l_bitow  <= 0;							-- wyzerowanie licznika odebranych bitow
       bufor	<= (others => '0');					-- wyzerowanie bufora bitow danych
       problem 	<= '0';							-- wyzerowanie rejestru bledu odbioru
       SLOWO	<= (others => '0');					-- wyzerowanie wyjsciowego slowa danych
       GOTOWE	<= '0';							-- wyzerowanie flagi potwierdzenia odbioru
       BLAD	<= '0';							-- wyzerowanie flagi wykrycia bledu w odbiorze

     elsif (rising_edge(C)) then					-- synchroniczna praca odbiornika

       GOTOWE     <= '0';						-- defaultowe skasowanie flagi potwierdzenia odbioru
       BLAD       <= '0';						-- defaultowe skasowanie flagi wykrycia bledu w odbiorze
       wejscie(0) <= RX;						-- zarejestrowanie synchroniczne stanu sygnalu RX
       if (N_RX = TRUE) then						-- badanie warunku zanegowania sygnalu szeregowego
         wejscie(0) <= not(RX);						-- zarejestrowanie synchroniczne zanegowanego sygnalu RX
       end if;								-- zakonczenie instukcji warunkowej
       wejscie(1) <= wejscie(0);					-- zarejestrowanie dwoch kolejnych stanow sygnalu RX

       case stan is							-- badanie aktualnego stanu maszyny stanow

         when CZEKANIE =>						-- obsluga stanu CZEKANIE
           l_czasu <= 0;						-- wyzerowanie licznika czasu bodu
           l_bitow <= 0;						-- wyzerowanie licznika odebranych bitow
           bufor   <= (others => '0');					-- wyzerowanie bufora bitow danych
           problem <= '0';						-- wyzerowanie rejestru bledu odbioru
           if (wejscie(1)='0' and wejscie(0)='1' and T_BODU/=0) then	-- wykrycie poczatku bitu START
             stan   <= START;						-- przejscie do stanu START
           end if;							-- zakonczenie instukcji warunkowej

         when START =>							-- obsluga stanu START
           if (l_czasu /= T_BODU/2) then				-- badanie odliczania pol okresu bodu
             l_czasu <= l_czasu + 1;					-- zwiekszenie o 1 stanu licznika czasu
           else								-- zakonczenie odliczania polowy okresu bodu
             l_czasu <= 0;						-- wyzerowanie licznika czasu bodu
             stan    <= DANA;						-- przejscie do stanu DANA
             if (wejscie(1) = '0') then					-- badanie nieprawidlowego stanu bitu START
	       report "SERIAL_RX: nieprawidlowa wartosc bitu startu"	-- informacja o bledzie odbioru
	         severity warning;
               problem <= '1';						-- ustawienie rejestru bledu odbioru
             end if;							-- zakonczenie instukcji warunkowej
           end if;							-- zakonczenie instukcji warunkowej

         when DANA =>							-- obsluga stanu DANA
           if (l_czasu /= T_BODU-1) then				-- badanie odliczania okresu bodu
             l_czasu <= l_czasu + 1;					-- zwiekszenie o 1 stanu licznika czasu
           else								-- zakonczenie odliczania okresu bodu
             bufor(bufor'left) <= wejscie(1);				-- zapamietanie stanu bitu danych
             bufor(bufor'left-1 downto 0) <= bufor(bufor'left downto 1);-- przesuniecie bitow w buforze
             l_czasu <= 0;						-- wyzerowanie licznika czasu bodu

             if (l_bitow /= B_SLOWA-1) then				-- badanie odliczania bitow danych
               l_bitow <= l_bitow + 1;					-- zwiekszenie o 1 liczby bitow danych
             else							-- zakonczenie odliczania bitow danych
               l_bitow <= 0;						-- wyzerowanie licznika odebranych bitow
               if (B_PARZYSTOSCI = 1) then				-- badanie odbioru bitu parzystosci
                 stan <= PARZYSTOSC;					-- przejscie do stanu PARZYSTOSC
               else							-- brak odbioru bitu parzystosci
                 stan <= STOP;						-- przejscie do stanu STOP
               end if;							-- zakonczenie instukcji warunkowej
             end if; 							-- zakonczenie instukcji warunkowej

           end if;							-- zakonczenie instukcji warunkowej

         when PARZYSTOSC =>						-- obsluga stanu PARZYSTOSC
           if (l_czasu /= T_BODU-1) then					-- badanie odliczania okresu bodu
             l_czasu <= l_czasu + 1;					-- zwiekszenie o 1 stanu licznika czasu
           else								-- zakonczenie odliczania okresu bodu
             l_czasu <= 0;						-- wyzerowanie licznika czasu bodu
             stan    <= STOP;						-- przejscie do stanu STOP
             if ((wejscie(1) xor XOR_REDUCE(bufor)) = '1') then 	-- badanie nieprawidlowej parzystosci bitow
               problem <= '1';						-- ustawienie rejestru bledu odbioru
	       report "SERIAL_RX: nieprawidlowa wartosc bitu parzystosci" -- informacja o bledzie odbioru
	         severity warning;
             end if; 							-- zakonczenie instukcji warunkowej
           end if;							-- zakonczenie instukcji warunkowej

         when STOP =>							-- obsluga stanu STOP
           if (l_czasu /= T_BODU-1) then					-- badanie odliczania okresu bodu
             l_czasu <= l_czasu + 1;					-- zwiekszenie o 1 stanu licznika czasu
           else								-- zakonczenie odliczania okresu bodu
             l_czasu <= 0;						-- wyzerowanie licznika czasu bodu

             if (l_bitow /= B_STOPOW-1) then				-- badanie odliczania bitow stopu
               l_bitow <= l_bitow + 1;					-- zwiekszenie o 1 liczby bitow stopu
               if (wejscie(1) = '1') then				-- badanie nieprawidlowego stanu bitu STOP
                 problem <= '1';					-- ustawienie rejestru bledu odbioru
	       report "SERIAL_RX: nieprawidlowa wartosc bitu stopu"	-- informacja o bledzie odbioru
	         severity warning;
               end if; 							-- zakonczenie instukcji warunkowej
             else							-- zakonczenie odliczania bitow stopu
               if (problem = '0' and wejscie(1) = '0') then		-- badanie prawidlowego odbioru szeregowego
                 SLOWO <= bufor;					-- ustawienie na wyjsciu SLOWO odebranego slowa
                 if (N_SLOWO = TRUE) then				-- badanie warunku zanegowania odebranego slowa
                   SLOWO <= not(bufor);					-- ustawienie na wyjsciu SLOWO odebranego slowa
                 end if;						-- zakonczenie instukcji warunkowej
                 GOTOWE <= '1';						-- ustawienie na wyjsciu flagi potwierdzenia
               else							-- wykryto nieprawidlowy odbioru szeregowy
                 SLOWO <= (others => '0');				-- wyzerowanie wyjscia danych
                 BLAD <= '1';						-- ustawienie na wyjsciu flagi bledu odbioru
               end if;							-- zakonczenie instukcji warunkowej
               stan <= CZEKANIE;					-- przejscie do stanu CZEKANIE
             end if;							-- zakonczenie instukcji warunkowej

           end if;							-- zakonczenie instukcji warunkowej

       end case;							-- zakonczenie instukcji warunkowego wyboru

     end if;								-- zakonczenie instukcji warunkowej porcesu

   end process;								-- zakonczenie ciala procesu

end behavioural;
