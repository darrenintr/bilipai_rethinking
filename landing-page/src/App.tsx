import Header from "./components/Header";
import Hero from "./components/Hero";
import Features from "./components/Features";
import Metrics from "./components/Metrics";
import Footer from "./components/Footer";

export default function App() {
  return (
    <div className="relative min-h-screen bg-white text-gray-900 overflow-x-hidden antialiased font-sans flex flex-col justify-between">
      <Header />
      <main className="flex-1 w-full flex flex-col">
        <Hero />
        <Features />
        <Metrics />
      </main>
      <Footer />
    </div>
  );
}
